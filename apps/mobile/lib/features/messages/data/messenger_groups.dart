part of 'messenger.dart';

/// A group as the server lists it for us (GET /me/groups).
class Group {
  Group({
    required this.groupId,
    required this.name,
    required this.description,
    required this.archived,
    required this.members,
  });
  final String groupId;
  final String name;
  final String? description;
  final bool archived;
  final List<GroupMember> members;

  GroupMember? member(String userId) => members.where((m) => m.userId == userId).firstOrNull;
}

class GroupMember {
  GroupMember({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.you,
    required this.linked,
    required this.suspended,
    required this.devices,
  });
  final String userId;
  final String username;
  final String displayName;
  final bool you;

  /// Also a direct contact. A member who is not can be read and mentioned in
  /// the group, never messaged one to one (the contact graph rule).
  final bool linked;
  final bool suspended;
  final List<DirectoryDevice> devices;
}

/// Groups (Phase 8b, decisions.md 2026-09-25).
///
/// Each of our devices has its own libsignal Sender Key per group. Before its
/// first group message (and after a rotation) it hands that key to every other
/// member device in a pairwise envelope ({"type":"skey"}), then encrypts each
/// group message ONCE. When a device that holds our key is no longer in the
/// group (someone left or was removed, or a device was revoked), the next send
/// starts a fresh key (a new distribution id) shared only with who is left.
///
/// Receiving, a group message is decrypted only under a distribution id that
/// SAME sender device handed us pairwise FOR THIS GROUP. A message whose key
/// has not arrived yet waits (sealed in the vault) and is retried when it does.
extension GroupEngine on Messenger {
  // ------------------------------------------------------------- directory

  Future<void> refreshGroups() async {
    final list = await api.get('/me/groups') as List<Object?>;
    final seen = <String>{};
    for (final raw in list) {
      final j = raw! as Map<String, Object?>;
      final g = Group(
        groupId: j['groupId']! as String,
        name: j['name']! as String,
        description: j['description'] as String?,
        archived: j['archived'] == true,
        members: [
          for (final m in (j['members']! as List<Object?>).cast<Map<String, Object?>>())
            GroupMember(
              userId: m['userId']! as String,
              username: m['username']! as String,
              displayName: m['displayName']! as String,
              you: m['you'] == true,
              linked: m['linked'] == true,
              suspended: m['suspended'] == true,
              devices: [
                for (final d in (m['devices']! as List<Object?>).cast<Map<String, Object?>>())
                  DirectoryDevice(d['deviceNumber']! as int, d['identityKey']! as String, d['platform'] as String?),
              ],
            ),
        ],
      );
      seen.add(g.groupId);
      _groups[g.groupId] = g;
      final chat = await store.chat(g.groupId);
      if (chat == null) {
        await store.putChat(ChatSummary(
          peerUserId: g.groupId,
          displayName: g.name,
          username: '',
          isGroup: true,
          left: g.archived,
          lastText: g.description ?? '',
          lastAt: DateTime.tryParse(j['joinedAt'] as String? ?? '') ?? DateTime.now(),
        ));
      } else if (chat.displayName != g.name || chat.left != g.archived) {
        chat
          ..displayName = g.name
          ..left = g.archived;
        await store.putChat(chat);
      }
    }
    // Groups we are no longer in: the chat stays, read-only.
    _groups.removeWhere((id, _) => !seen.contains(id));
    for (final chat in await store.chats()) {
      if (chat.isGroup && !seen.contains(chat.peerUserId) && !chat.left) {
        chat.left = true;
        await store.putChat(chat);
      }
    }
    changed();
  }

  /// Every device our group messages must reach: each member's, and our own
  /// other devices, never this one.
  List<(String, int)> _groupTargets(Group g) => [
        for (final m in g.members)
          for (final d in m.devices)
            if (!(m.userId == me && d.deviceNumber == session.deviceNumber)) (m.userId, d.deviceNumber),
      ];

  // --------------------------------------------------------------- sending

  Future<void> _postGroup(String groupId, String messageId, Map<String, Object?> content,
      {List<String>? attachmentIds}) async {
    final bytes = utf8.encode(jsonEncode({...content, 'group': groupId}));
    for (var attempt = 0; attempt < 3; attempt++) {
      var g = _groups[groupId];
      if (g == null) {
        await refreshGroups();
        g = _groups[groupId];
      }
      if (g == null || g.archived) throw ApiException(404);
      final targets = _groupTargets(g);
      final keys = {for (final t in targets) '${t.$1}:${t.$2}'};

      var state = await _outgoingKey(groupId);
      // Someone who holds our current key is gone: start a new one.
      if (state == null || state.shared.any((k) => !keys.contains(k))) {
        state = _OutgoingKey(_uuid.v4(), {});
      }
      final need = [for (final t in targets) if (!state.shared.contains('${t.$1}:${t.$2}')) t];
      try {
        if (need.isNotEmpty) {
          final skdm = await crypto.groupSenderKey(distributionId: state.distributionId);
          await _shareSenderKey(groupId, need, skdm);
          state.shared.addAll([for (final t in need) '${t.$1}:${t.$2}']);
          await _saveOutgoingKey(groupId, state);
        }
        final body = await crypto.groupEncrypt(distributionId: state.distributionId, plaintext: bytes);
        await api.post('/groups/$groupId/messages', {
          'messageId': messageId,
          'body': base64.encode(body),
          'devices': [for (final t in targets) {'userId': t.$1, 'deviceNumber': t.$2}],
          if (attachmentIds != null) 'attachmentIds': attachmentIds,
        });
        return;
      } on ApiException catch (e) {
        if (e.status != 409) rethrow;
        // The member list changed under us: learn it and try again.
        await refreshGroups();
      }
    }
    throw ApiException(409);
  }

  /// Hands our sender key to [targets], each in its own pairwise envelope.
  Future<void> _shareSenderKey(String groupId, List<(String, int)> targets, Uint8List skdm) async {
    await _ensureGroupSessions(groupId, targets);
    final bytes = utf8.encode(jsonEncode({'v': 1, 'type': 'skey', 'group': groupId, 'skdm': base64.encode(skdm)}));
    final envelopes = <Map<String, Object?>>[];
    for (final t in targets) {
      final e = await crypto.encrypt(userId: t.$1, deviceNumber: t.$2, plaintext: bytes);
      envelopes.add({
        'userId': t.$1,
        'deviceNumber': t.$2,
        'kind': e.kind == EnvelopeKind.preKey ? 'prekey' : 'whisper',
        'body': base64.encode(e.body),
      });
    }
    await api.post('/groups/$groupId/key-shares', {'messageId': _uuid.v4(), 'envelopes': envelopes});
  }

  /// Sessions with member devices we have never talked to, from bundles the
  /// server hands out only to fellow members.
  Future<void> _ensureGroupSessions(String groupId, List<(String, int)> targets) async {
    final need = <String, Set<int>>{};
    for (final t in targets) {
      if (!await crypto.hasSession(userId: t.$1, deviceNumber: t.$2)) {
        need.putIfAbsent(t.$1, () => {}).add(t.$2);
      }
    }
    for (final entry in need.entries) {
      final path = entry.key == me ? '/me/device-keys' : '/groups/$groupId/keys?userId=${entry.key}';
      final j = await api.get(path) as Map<String, Object?>;
      for (final raw in j['devices']! as List<Object?>) {
        final d = raw! as Map<String, Object?>;
        if (!entry.value.contains(d['deviceNumber']! as int)) continue;
        await crypto.startSession(userId: entry.key, bundle: _bundle(d));
      }
    }
  }

  Future<_OutgoingKey?> _outgoingKey(String groupId) async {
    final j = await store.setting('skOut:$groupId') as Map<String, Object?>?;
    if (j == null) return null;
    return _OutgoingKey(j['dist']! as String, {for (final k in j['shared']! as List<Object?>) k! as String});
  }

  Future<void> _saveOutgoingKey(String groupId, _OutgoingKey k) =>
      store.putSetting('skOut:$groupId', {'dist': k.distributionId, 'shared': k.shared.toList()});

  // ------------------------------------------------------------- receiving

  /// A member device's sender key, from a pairwise envelope that decrypted as
  /// coming from exactly that device (which is what authenticates it).
  Future<void> _acceptSenderKey(String sender, int device, Map<String, Object?> content) async {
    final groupId = content['group'] as String?;
    final skdm = content['skdm'] as String?;
    if (groupId == null || skdm == null) return;
    var g = _groups[groupId];
    if (g == null || g.member(sender) == null) {
      await refreshGroups();
      g = _groups[groupId];
    }
    if (g == null || g.member(sender) == null) return; // not a member: ignore it
    final String dist;
    try {
      dist = await crypto.acceptGroupSenderKey(userId: sender, deviceNumber: device, distributionMessage: base64.decode(skdm));
    } on Object {
      return;
    }
    final accepted = (await store.setting('skIn:$groupId') as Map<String, Object?>?) ?? {};
    final who = '$sender:$device';
    final list = [...(accepted[who] as List<Object?>? ?? const [])];
    if (!list.contains(dist)) list.add(dist);
    await store.putSetting('skIn:$groupId', {...accepted, who: list});
    await _retryPending(groupId, sender, device);
  }

  Future<void> _receiveGroup(Map<String, Object?> e) async {
    final groupId = e['groupId'] as String?;
    final sender = e['senderUserId']! as String;
    final device = e['senderDeviceNumber']! as int;
    if (groupId == null) return;
    if (sender == me && device == session.deviceNumber) return;
    final body = base64.decode(e['body']! as String);
    String dist;
    try {
      dist = await crypto.groupMessageDistributionId(body: body);
    } on Object {
      await _notice(groupId, NoticeType.undecryptable, {'deviceNumber': device});
      return;
    }
    final accepted = (await store.setting('skIn:$groupId') as Map<String, Object?>?) ?? {};
    final mine = (accepted['$sender:$device'] as List<Object?>? ?? const []).contains(dist);
    if (!mine) {
      await _pend(e); // its key has not arrived (yet)
      return;
    }
    Uint8List plain;
    try {
      plain = await crypto.groupDecrypt(userId: sender, deviceNumber: device, body: body, distributionId: dist);
    } on Object {
      await _notice(groupId, NoticeType.undecryptable, {'deviceNumber': device});
      return;
    }
    Map<String, Object?> content;
    try {
      content = jsonDecode(utf8.decode(plain)) as Map<String, Object?>;
    } on Object {
      return;
    }
    if (content['group'] != groupId) return; // meant for another group: drop it
    await _handleContent(groupId, sender, device, content, group: true);
  }

  static const _maxPending = 300;

  Future<void> _pend(Map<String, Object?> e) async {
    final list = [...?(await store.setting('skPending') as List<Object?>?)];
    list.add(e);
    while (list.length > _maxPending) {
      list.removeAt(0);
    }
    await store.putSetting('skPending', list);
  }

  Future<void> _retryPending(String groupId, String sender, int device) async {
    final list = [...?(await store.setting('skPending') as List<Object?>?)];
    final mine = <Map<String, Object?>>[];
    list.removeWhere((raw) {
      final e = raw! as Map<String, Object?>;
      final match = e['groupId'] == groupId && e['senderUserId'] == sender && e['senderDeviceNumber'] == device;
      if (match) mine.add(e);
      return match;
    });
    if (mine.isEmpty) return;
    await store.putSetting('skPending', list);
    for (final e in mine) {
      await _receiveGroup(e);
    }
  }

  // ----------------------------------------------------- notices and leaving

  /// The server's group notices: created, renamed, joined, removed, left,
  /// archived, reopened. Facts only, never content.
  Future<void> _groupNotice(String groupId, Map<String, Object?> event) async {
    await refreshGroups().catchError((Object _) {});
    final type = event['type']! as String;
    final chat = await _ensureChat(groupId);
    if (type == 'group_renamed' && event['to'] is String) {
      chat.displayName = event['to']! as String;
    }
    if (type == 'group_archived' || (type == 'group_member_removed' && event['userId'] == me)) {
      chat.left = true;
    }
    if (type == 'group_reopened') chat.left = false;
    await store.putChat(chat);
    await _notice(groupId, NoticeType.groupEvent, {
      'event': type,
      'userId': event['userId'],
      'name': event['displayName'],
      'from': event['from'],
      'to': event['to'],
      'you': event['userId'] == me,
    });
  }

  /// Leave a group (board 29). Only an administrator can add us back.
  Future<void> leaveGroup(String groupId) async {
    await api.post('/groups/$groupId/leave');
    final chat = await _ensureChat(groupId);
    chat.left = true;
    await store.putChat(chat);
    await store.putSetting('skOut:$groupId', null);
    await refreshGroups().catchError((Object _) {});
    changed();
  }

  bool _isGroupChat(String peer) => _groups.containsKey(peer);
}

class _OutgoingKey {
  _OutgoingKey(this.distributionId, this.shared);
  final String distributionId;

  /// "userId:deviceNumber" of every device we handed this key to.
  final Set<String> shared;
}
