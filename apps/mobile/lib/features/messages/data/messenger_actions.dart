part of 'messenger.dart';

/// Board 28: what you can do to a message after it is sent. Every one of
/// these is itself an encrypted message that points at an earlier one, sent
/// to the same people (the peer and our other devices, or the group):
///
///   {"type":"edit","target","body","sentAt"}     the author, within 15 minutes
///   {"type":"delete","target","sentAt"}          the author, within 24 hours
///   {"type":"react","target","emoji"}            anyone in the chat; null removes
///   {"type":"pin","target","pinned","sentAt"}    anyone in the chat; announced
///
/// The time limits and the authorship are checked by every receiving device
/// (owner decision, decisions.md 2026-09-25): an edit or deletion that breaks
/// them is ignored. A modified app could still send one; it would not show.
extension MessageActions on Messenger {
  static const editWindow = Duration(minutes: 15);
  static const deleteWindow = Duration(hours: 24);
  static const maxPins = 3;
  // Clocks differ a little between devices.
  static const _slack = Duration(minutes: 2);

  bool canEdit(LocalMessage m) =>
      m.fromMe && m.kind == MessageKind.text && !m.deleted && DateTime.now().difference(m.sentAt) < editWindow;

  bool canDeleteForEveryone(LocalMessage m) =>
      m.fromMe && !m.isNotice && !m.deleted && DateTime.now().difference(m.sentAt) < deleteWindow;

  // ------------------------------------------------------------- sending

  Future<void> editMessage(String messageId, String text) async {
    final m = await store.message(messageId);
    if (m == null || !canEdit(m) || text.trim().isEmpty || text == m.text) return;
    final now = DateTime.now();
    m
      ..text = text
      ..editedAt = now;
    await store.putMessage(m);
    await _refreshPreview(m.peerUserId);
    changed();
    await _sendControl(m.peerUserId, {'type': 'edit', 'target': m.id, 'body': text, 'sentAt': now.millisecondsSinceEpoch});
  }

  Future<void> deleteForEveryone(String messageId) async {
    final m = await store.message(messageId);
    if (m == null || !canDeleteForEveryone(m)) return;
    await _markDeleted(m);
    await _sendControl(m.peerUserId, {
      'type': 'delete',
      'target': m.id,
      'sentAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Gone from this device only; always allowed.
  Future<void> deleteForMe(String messageId) async {
    final m = await store.message(messageId);
    if (m == null) return;
    for (final i in m.items) {
      await media.delete(i);
    }
    await store.deleteMessage(m.id);
    final chat = await store.chat(m.peerUserId);
    if (chat != null && chat.pins.remove(m.id)) await store.putChat(chat);
    changed();
  }

  /// One reaction per person; the same emoji again takes it back.
  Future<void> react(String messageId, String emoji) async {
    final m = await store.message(messageId);
    if (m == null || m.deleted || m.isNotice) return;
    final next = m.reactions[me] == emoji ? null : emoji;
    if (next == null) {
      m.reactions.remove(me);
    } else {
      m.reactions[me] = next;
    }
    await store.putMessage(m);
    changed();
    await _sendControl(m.peerUserId, {'type': 'react', 'target': m.id, 'emoji': next});
  }

  Future<void> pin(String messageId, bool pinned) async {
    final m = await store.message(messageId);
    if (m == null || m.deleted || m.isNotice) return;
    final now = DateTime.now();
    await _applyPin(m, pinned, byMe: true, name: null, at: now);
    await _sendControl(m.peerUserId, {
      'type': 'pin',
      'target': m.id,
      'pinned': pinned,
      'sentAt': now.millisecondsSinceEpoch,
    });
  }

  /// Sends a control message now, or queues it for when we are online.
  Future<void> _sendControl(String peer, Map<String, Object?> content) async {
    final full = {'v': 1, 'id': _uuid.v4(), 'peer': peer, ...content};
    try {
      await _postAny(peer, full['id']! as String, full);
    } on ApiException catch (e) {
      if (!e.offline) return;
      final queue = [...?(await store.setting('controlOutbox') as List<Object?>?)];
      queue.add({'peer': peer, 'content': full});
      await store.putSetting('controlOutbox', queue);
    } on Object {
      // Refused by the protocol: nothing to retry.
    }
  }

  Future<void> _flushControl() async {
    final queue = (await store.setting('controlOutbox') as List<Object?>?) ?? const [];
    if (queue.isEmpty) return;
    final left = <Object?>[];
    for (final raw in queue) {
      final e = raw! as Map<String, Object?>;
      final content = e['content']! as Map<String, Object?>;
      try {
        await _postAny(e['peer']! as String, content['id']! as String, content);
      } on ApiException catch (err) {
        if (err.offline) left.add(e);
      } on Object {
        // drop it
      }
    }
    await store.putSetting('controlOutbox', left);
  }

  Future<void> _postAny(String peer, String id, Map<String, Object?> content) async {
    if (await _isGroup(peer)) {
      await _postGroup(peer, id, content);
    } else {
      await _post(peer, id, content);
    }
  }

  // ----------------------------------------------------------- receiving

  /// An edit, deletion, reaction or pin from [sender] in the chat [peer].
  Future<void> _applyControl(String peer, String sender, Map<String, Object?> content, {String? senderName}) async {
    final target = content['target'];
    if (target is! String) return;
    final m = await store.message(target);
    if (m == null || m.peerUserId != peer) return; // only this chat's messages
    final sentAt = DateTime.fromMillisecondsSinceEpoch((content['sentAt'] as int?) ?? DateTime.now().millisecondsSinceEpoch);
    final byAuthor = (m.fromMe ? me : m.author) == sender;
    switch (content['type']) {
      case 'edit':
        final body = content['body'];
        if (!byAuthor || m.deleted || body is! String || m.kind != MessageKind.text) return;
        if (sentAt.difference(m.sentAt) > editWindow + _slack) return; // too late: ignored
        m
          ..text = body
          ..editedAt = sentAt;
        await store.putMessage(m);
        await _refreshPreview(peer);
      case 'delete':
        if (!byAuthor || m.deleted) return;
        if (sentAt.difference(m.sentAt) > deleteWindow + _slack) return;
        await _markDeleted(m);
      case 'react':
        final emoji = content['emoji'];
        if (m.deleted) return;
        if (emoji is String && emoji.isNotEmpty && emoji.runes.length <= 8) {
          m.reactions[sender] = emoji;
        } else {
          m.reactions.remove(sender);
        }
        await store.putMessage(m);
      case 'pin':
        if (m.deleted) return;
        await _applyPin(m, content['pinned'] == true, byMe: sender == me, name: senderName, at: sentAt);
    }
    changed();
  }

  Future<void> _markDeleted(LocalMessage m) async {
    for (final i in m.items) {
      await media.delete(i);
    }
    m
      ..deleted = true
      ..text = ''
      ..items.clear()
      ..reactions.clear();
    await store.putMessage(m);
    final chat = await store.chat(m.peerUserId);
    if (chat != null && chat.pins.remove(m.id)) await store.putChat(chat);
    await _refreshPreview(m.peerUserId);
    changed();
  }

  /// The chat list's line follows the newest message after an edit or a
  /// deletion, so it never shows words that were taken back.
  Future<void> _refreshPreview(String peer) async {
    final chat = await store.chat(peer);
    if (chat == null) return;
    final latest = (await store.messages(peer, limit: 30)).where((x) => !x.isNotice).firstOrNull;
    if (latest == null) return;
    final body = latest.deleted ? 'This message was deleted' : _preview(latest);
    final who = !chat.isGroup
        ? ''
        : latest.fromMe
            ? 'You: '
            : '${(latest.senderName ?? 'Someone').split(' ').first}: ';
    final line = '$who$body';
    if (chat.lastText != line) {
      chat.lastText = line;
      await store.putChat(chat);
    }
  }

  Future<void> _applyPin(LocalMessage m, bool pinned, {required bool byMe, String? name, required DateTime at}) async {
    final chat = await _ensureChat(m.peerUserId);
    final had = chat.pins.contains(m.id);
    if (pinned == had) return;
    if (pinned) {
      chat.pins.add(m.id);
      while (chat.pins.length > maxPins) {
        chat.pins.removeAt(0);
      }
    } else {
      chat.pins.remove(m.id);
    }
    await store.putChat(chat);
    // Announced, so nobody can quietly pin (board 27).
    await store.putMessage(LocalMessage(
      id: _uuid.v4(),
      peerUserId: m.peerUserId,
      fromMe: byMe,
      sentAt: at,
      kind: MessageKind.notice,
      notice: NoticeType.pinned,
      noticeData: {'pinned': pinned, 'byMe': byMe, if (name != null) 'name': name},
      status: MessageStatus.delivered,
    ));
  }

  /// What a reply quotes ({id, author, name, preview}).
  Map<String, Object?> quoteOf(LocalMessage m) => {
        'id': m.id,
        'author': m.fromMe ? me : m.author,
        if (!m.fromMe) 'name': m.senderName ?? _contacts[m.peerUserId]?.displayName,
        'preview': m.deleted ? 'Deleted message' : (m.isMedia ? (m.text.isEmpty ? m.mediaLabel : m.text) : m.text),
      };
}
