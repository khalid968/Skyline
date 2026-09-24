import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/session.dart';
import '../../../core/crypto/device_crypto.dart';
import '../../../core/realtime/realtime_client.dart';
import '../../auth/data/prekeys.dart';
import '../domain/models.dart';
import 'local_store.dart';

/// A contact as the directory reports them, with their reachable devices.
class Contact {
  Contact({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.suspended,
    required this.devices,
  });
  final String userId;
  final String username;
  final String displayName;
  final bool suspended;
  final List<DirectoryDevice> devices;
}

class DirectoryDevice {
  DirectoryDevice(this.deviceNumber, this.identityKey, this.platform);
  final int deviceNumber;
  final String identityKey; // base64
  final String? platform;
}

/// The messaging engine (decisions.md, "How messages move").
///
/// Sending: one ciphertext per live device, the contact's and our own other
/// devices; a 409 names devices to add or drop, and we retry.
/// Receiving: a nudge (socket, later push) or a reconnect triggers a pull of
/// this device's inbox; each envelope is decrypted, stored in the vault, then
/// acknowledged, which makes the server erase its copy.
///
/// Plaintext inside every envelope is a small JSON document:
///   {"v":1,"type":"text","id","peer","body","sentAt","timer"}
///   {"v":1,"type":"read","peer","ids":[...]}      read receipt
///   {"v":1,"type":"timer","id","peer","seconds","sentAt"}
///   {"v":1,"type":"typing","peer","on"}            (live signals only)
/// `peer` is the other person in the chat from the SENDER's point of view, so
/// our own other devices know which chat a message we sent belongs to.
class Messenger extends ChangeNotifier {
  Messenger({
    required this.api,
    required this.crypto,
    required this.store,
    required this.realtime,
    required this.session,
  });

  final ApiClient api;
  final CryptoDevice crypto;
  final LocalStore store;
  final RealtimeClient realtime;
  final Session session;

  final _uuid = const Uuid();
  final Map<String, Contact> _contacts = {};
  final Map<int, String> _ownIdentities = {}; // our other devices
  final Map<String, DateTime> _typingUntil = {};
  StreamSubscription<RealtimeEvent>? _eventsSub;
  StreamSubscription<ConnectionStatus>? _statusSub;
  Timer? _sweeper;
  bool _syncing = false;
  bool _syncAgain = false;
  bool signedOut = false;
  ConnectionStatus connection = ConnectionStatus.offline;
  String? openChat;

  String get me => session.userId;
  List<Contact> get contacts => _contacts.values.toList()
    ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
  Contact? contact(String userId) => _contacts[userId];
  bool isTyping(String peer) => (_typingUntil[peer]?.isAfter(DateTime.now())) ?? false;

  // ------------------------------------------------------------ lifecycle

  Future<void> start() async {
    _eventsSub = realtime.events.listen(_onEvent);
    _statusSub = realtime.status.listen((s) {
      connection = s;
      notifyListeners();
      if (s == ConnectionStatus.online) unawaited(_flushOutbox());
    });
    _sweeper = Timer.periodic(const Duration(seconds: 15), (_) => sweepExpired());
    unawaited(refreshContacts().catchError((Object _) {}));
    unawaited(_topUpKeys());
    realtime.start();
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    _statusSub?.cancel();
    _sweeper?.cancel();
    unawaited(realtime.stop());
    super.dispose();
  }

  void _onEvent(RealtimeEvent e) {
    switch (e.type) {
      case 'inbox':
        unawaited(sync());
      case 'receipt':
        unawaited(_onDeliveredReceipt(e.payload));
      case 'signal':
        unawaited(_onSignal(e.from, e.payload));
      case 'signed_out':
        signedOut = true;
        notifyListeners();
    }
  }

  // --------------------------------------------------------- directory

  /// Refreshes who we can talk to, and notices new devices (board 17).
  Future<void> refreshContacts() async {
    final list = await api.get('/me/contacts') as List<Object?>;
    final seen = <String>{};
    for (final raw in list) {
      final j = raw! as Map<String, Object?>;
      final c = Contact(
        userId: j['userId']! as String,
        username: j['username']! as String,
        displayName: j['displayName']! as String,
        suspended: j['suspended'] == true,
        devices: [
          for (final d in (j['devices']! as List<Object?>).cast<Map<String, Object?>>())
            DirectoryDevice(
              d['deviceNumber']! as int,
              d['identityKey']! as String,
              d['platform'] as String?,
            ),
        ],
      );
      seen.add(c.userId);
      _contacts[c.userId] = c;
      await _reconcileDevices(c);
      final chat = await store.chat(c.userId);
      if (chat != null && (chat.displayName != c.displayName || chat.username != c.username)) {
        chat
          ..displayName = c.displayName
          ..username = c.username;
        await store.putChat(chat);
      }
    }
    _contacts.removeWhere((id, _) => !seen.contains(id));
    await _refreshOwnDevices();
    notifyListeners();
  }

  Future<void> _refreshOwnDevices() async {
    final list = await api.get('/me/devices') as List<Object?>;
    _ownIdentities.clear();
    for (final raw in list) {
      final d = raw! as Map<String, Object?>;
      if (d['current'] == true || d['identityKey'] == null) continue;
      _ownIdentities[d['deviceNumber']! as int] = d['identityKey']! as String;
    }
  }

  /// Records a contact's devices. The first time we see a contact we just
  /// remember them; after that, a device we have not seen before gets an
  /// "added a new device" notice in the chat.
  Future<void> _reconcileDevices(Contact c) async {
    final known = {for (final d in await store.devicesOf(c.userId)) d.deviceNumber: d};
    final firstLook = known.isEmpty;
    for (final d in c.devices) {
      if (known.containsKey(d.deviceNumber)) continue;
      await store.putDevice(KnownDevice(
        userId: c.userId,
        deviceNumber: d.deviceNumber,
        identityKey: d.identityKey,
        firstSeen: DateTime.now(),
        platform: d.platform,
      ));
      if (!firstLook && await store.chat(c.userId) != null) {
        await _notice(c.userId, NoticeType.newDevice, {
          'deviceNumber': d.deviceNumber,
          'platform': d.platform,
        });
      }
    }
  }

  // ----------------------------------------------------------- sending

  Future<LocalMessage> sendText(String peer, String text) async {
    // The first message in a new chat carries this person's default timer
    // (board 13), announced like any timer change.
    final isNew = await store.chat(peer) == null ||
        (await store.messages(peer, limit: 1)).isEmpty;
    final fallback = await defaultTimer();
    if (isNew && fallback != null && (await store.chat(peer))?.timerSeconds == null) {
      await setTimer(peer, fallback);
    }
    final chat = await _ensureChat(peer);
    final now = DateTime.now();
    final m = LocalMessage(
      id: _uuid.v4(),
      peerUserId: peer,
      fromMe: true,
      sentAt: now,
      text: text,
      status: MessageStatus.sending,
      senderDevice: session.deviceNumber,
      timerSeconds: chat.timerSeconds,
      expiresAt: chat.timerSeconds == null ? null : now.add(Duration(seconds: chat.timerSeconds!)),
    );
    await store.putMessage(m);
    await _touchChat(chat, text, now, unread: false);
    notifyListeners();
    await _deliver(m, {
      'v': 1,
      'type': 'text',
      'id': m.id,
      'peer': peer,
      'body': text,
      'sentAt': now.millisecondsSinceEpoch,
      'timer': chat.timerSeconds,
    });
    return m;
  }

  /// Sets the disappearing-message timer for a chat (board 15). The change is
  /// itself a message, so both sides see it announced.
  Future<void> setTimer(String peer, int? seconds) async {
    final chat = await _ensureChat(peer);
    chat.timerSeconds = seconds;
    await store.putChat(chat);
    final now = DateTime.now();
    final m = LocalMessage(
      id: _uuid.v4(),
      peerUserId: peer,
      fromMe: true,
      sentAt: now,
      kind: MessageKind.notice,
      notice: NoticeType.timerChanged,
      noticeData: {'seconds': seconds, 'byMe': true},
      status: MessageStatus.sending,
    );
    await store.putMessage(m);
    notifyListeners();
    await _deliver(m, {
      'v': 1,
      'type': 'timer',
      'id': m.id,
      'peer': peer,
      'seconds': seconds,
      'sentAt': now.millisecondsSinceEpoch,
    });
  }

  Future<void> retry(String messageId) async {
    final m = await store.message(messageId);
    if (m == null || m.status != MessageStatus.failed) return;
    m.status = MessageStatus.sending;
    await store.putMessage(m);
    notifyListeners();
    await _deliver(m, _contentFor(m));
  }

  Map<String, Object?> _contentFor(LocalMessage m) => m.isNotice
      ? {
          'v': 1,
          'type': 'timer',
          'id': m.id,
          'peer': m.peerUserId,
          'seconds': m.noticeData['seconds'],
          'sentAt': m.sentAt.millisecondsSinceEpoch,
        }
      : {
          'v': 1,
          'type': 'text',
          'id': m.id,
          'peer': m.peerUserId,
          'body': m.text,
          'sentAt': m.sentAt.millisecondsSinceEpoch,
          'timer': m.timerSeconds,
        };

  /// Encrypts [content] for every device and posts it. Offline: the message
  /// waits (board 19) and goes out on reconnect. Refused by the protocol
  /// (e.g. a changed identity): it fails, visibly.
  Future<void> _deliver(LocalMessage m, Map<String, Object?> content) async {
    try {
      await _post(m.peerUserId, m.id, content);
      m.status = MessageStatus.sent;
    } on ApiException catch (e) {
      m.status = e.offline ? MessageStatus.waiting : MessageStatus.failed;
    } on CryptoException {
      m.status = MessageStatus.failed;
    } on SignedOutException {
      signedOut = true;
      m.status = MessageStatus.failed;
    }
    await store.putMessage(m);
    notifyListeners();
  }

  /// Posts [content] to [peer] and our own other devices, fixing the device
  /// list when the server says it is stale.
  Future<void> _post(String peer, String messageId, Map<String, Object?> content) async {
    final bytes = utf8.encode(jsonEncode(content));
    var targets = await _targets(peer);
    for (var attempt = 0; attempt < 3; attempt++) {
      await _ensureSessions(peer, targets);
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
      try {
        await api.post('/users/$peer/messages', {'messageId': messageId, 'envelopes': envelopes});
        return;
      } on ApiException catch (e) {
        if (e.status != 409 || e.body is! Map) rethrow;
        final body = e.body! as Map<String, Object?>;
        final missing = [
          for (final x in (body['missing'] as List<Object?>? ?? const []))
            ((x! as Map<String, Object?>)['userId']! as String, x['deviceNumber']! as int),
        ];
        final extra = {
          for (final x in (body['extra'] as List<Object?>? ?? const []))
            '${(x! as Map<String, Object?>)['userId']}:${x['deviceNumber']}',
        };
        targets = [
          for (final t in targets)
            if (!extra.contains('${t.$1}:${t.$2}')) t,
          ...missing,
        ];
        // The directory changed: learn about new devices (and announce them).
        unawaited(refreshContacts().catchError((Object _) {}));
      }
    }
    throw ApiException(409);
  }

  Future<List<(String, int)>> _targets(String peer) async {
    final c = _contacts[peer];
    return [
      if (c != null) for (final d in c.devices) (peer, d.deviceNumber),
      for (final n in _ownIdentities.keys) (me, n),
    ];
  }

  /// Starts a session (PQXDH) with any target device we have none with, from
  /// bundles fetched through the graph-checked key directory.
  Future<void> _ensureSessions(String peer, List<(String, int)> targets) async {
    final need = <String, Set<int>>{};
    for (final t in targets) {
      if (!await crypto.hasSession(userId: t.$1, deviceNumber: t.$2)) {
        need.putIfAbsent(t.$1, () => {}).add(t.$2);
      }
    }
    for (final entry in need.entries) {
      final path = entry.key == me ? '/me/device-keys' : '/users/${entry.key}/keys';
      final j = await api.get(path) as Map<String, Object?>;
      for (final raw in j['devices']! as List<Object?>) {
        final d = raw! as Map<String, Object?>;
        final n = d['deviceNumber']! as int;
        if (!entry.value.contains(n)) continue;
        await crypto.startSession(userId: entry.key, bundle: _bundle(d));
      }
    }
  }

  PreKeyBundle _bundle(Map<String, Object?> d) {
    SignedPreKey signed(Object? raw) {
      final k = raw! as Map<String, Object?>;
      return SignedPreKey(
        keyId: k['keyId']! as int,
        publicKey: base64.decode(k['publicKey']! as String),
        signature: base64.decode(k['signature']! as String),
      );
    }

    final pre = d['preKey'] as Map<String, Object?>?;
    return PreKeyBundle(
      registrationId: d['registrationId']! as int,
      deviceNumber: d['deviceNumber']! as int,
      identityKey: base64.decode(d['identityKey']! as String),
      signedPreKey: signed(d['signedPreKey']),
      kyberPreKey: signed(d['kyberPreKey']),
      preKey: pre == null
          ? null
          : OneTimePreKey(
              keyId: pre['keyId']! as int,
              publicKey: base64.decode(pre['publicKey']! as String),
            ),
    );
  }

  Future<void> _flushOutbox() async {
    for (final chat in await store.chats()) {
      for (final m in await store.messages(chat.peerUserId, limit: 200)) {
        if (m.fromMe && m.status == MessageStatus.waiting) {
          m.status = MessageStatus.sending;
          await _deliver(m, _contentFor(m));
        }
      }
    }
  }

  // --------------------------------------------------------- receiving

  /// Pulls and processes this device's inbox until it is empty. Re-entrant
  /// calls while a pull runs just schedule one more pass.
  Future<void> sync() async {
    if (_syncing) {
      _syncAgain = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _syncAgain = false;
        final box = await api.get('/me/inbox') as Map<String, Object?>;
        final acks = <String>[];
        for (final raw in box['envelopes']! as List<Object?>) {
          final e = raw! as Map<String, Object?>;
          await _receive(e);
          acks.add(e['envelopeId']! as String);
        }
        int? systemSeq;
        for (final raw in box['system']! as List<Object?>) {
          final s = raw! as Map<String, Object?>;
          await _systemNotice(s);
          systemSeq = s['seq']! as int;
        }
        if (acks.isNotEmpty || systemSeq != null) {
          await api.post('/me/inbox/ack', {
            'envelopeIds': acks,
            if (systemSeq != null) 'systemSeq': systemSeq,
          });
        }
        if (box['more'] == true) _syncAgain = true;
      } while (_syncAgain);
      unawaited(_topUpKeys());
    } on SignedOutException {
      signedOut = true;
    } on ApiException {
      // Offline or the server is unhappy: the next nudge or reconnect retries.
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> _receive(Map<String, Object?> e) async {
    final sender = e['senderUserId']! as String;
    final device = e['senderDeviceNumber']! as int;
    final kind = e['kind'] == 'prekey' ? EnvelopeKind.preKey : EnvelopeKind.whisper;
    final fromMe = sender == me;
    Uint8List plain;
    try {
      plain = await crypto.decrypt(
        userId: sender,
        deviceNumber: device,
        envelope: Envelope(kind: kind, body: base64.decode(e['body']! as String)),
        directoryIdentityKey: await _directoryIdentity(sender, device),
      );
    } on CryptoException catch (err) {
      // Refused: never shown, never opened. Board 17's red notice.
      final peer = fromMe ? null : sender;
      if (peer != null) {
        await _notice(
          peer,
          err.kind == CryptoErrorKind.untrustedIdentity ? NoticeType.blocked : NoticeType.undecryptable,
          {'deviceNumber': device},
        );
      }
      return;
    }

    Map<String, Object?> content;
    try {
      content = jsonDecode(utf8.decode(plain)) as Map<String, Object?>;
    } on Object {
      return;
    }
    // The chat: from a contact it is the sender; from our own other device it
    // is whoever that device addressed.
    final peer = fromMe ? content['peer'] as String? : sender;
    if (peer == null) return;
    final sentAt = DateTime.fromMillisecondsSinceEpoch(
      (content['sentAt'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
    );

    switch (content['type']) {
      case 'text':
        final id = content['id']! as String;
        if (await store.message(id) != null) return; // already have it
        final timer = content['timer'] as int?;
        final m = LocalMessage(
          id: id,
          peerUserId: peer,
          fromMe: fromMe,
          sentAt: sentAt,
          text: (content['body'] as String?) ?? '',
          status: fromMe ? MessageStatus.sent : MessageStatus.delivered,
          senderDevice: device,
          timerSeconds: timer,
          // Our own copies start their timer when sent; received ones when read.
          expiresAt: fromMe && timer != null ? sentAt.add(Duration(seconds: timer)) : null,
        );
        await store.putMessage(m);
        final chat = await _ensureChat(peer);
        await _touchChat(chat, m.text, sentAt, unread: !fromMe && openChat != peer);
        if (!fromMe) _typingUntil.remove(peer);
        if (!fromMe && openChat == peer) unawaited(markRead(peer));
      case 'timer':
        final seconds = content['seconds'] as int?;
        final chat = await _ensureChat(peer);
        chat.timerSeconds = seconds;
        await store.putChat(chat);
        await store.putMessage(LocalMessage(
          id: (content['id'] as String?) ?? _uuid.v4(),
          peerUserId: peer,
          fromMe: fromMe,
          sentAt: sentAt,
          kind: MessageKind.notice,
          notice: NoticeType.timerChanged,
          noticeData: {'seconds': seconds, 'byMe': fromMe},
          status: MessageStatus.delivered,
        ));
      case 'read':
        // A read receipt: from the contact (their device read our messages),
        // or from our own other device (we read theirs there).
        final ids = [for (final x in (content['ids'] as List<Object?>? ?? const [])) x! as String];
        for (final id in ids) {
          final m = await store.message(id);
          if (m == null) continue;
          if (!fromMe && m.fromMe) {
            if (await readReceiptsEnabled()) m.status = MessageStatus.read;
          } else if (fromMe && !m.fromMe) {
            _startTimerOnRead(m);
          }
          await store.putMessage(m);
        }
        if (fromMe) {
          final chat = await store.chat(peer);
          if (chat != null && chat.unread > 0) {
            chat.unread = 0;
            await store.putChat(chat);
          }
        }
    }
  }

  Future<Uint8List?> _directoryIdentity(String userId, int device) async {
    String? b64;
    if (userId == me) {
      b64 = _ownIdentities[device];
      if (b64 == null) {
        await _refreshOwnDevices();
        b64 = _ownIdentities[device];
      }
    } else {
      var c = _contacts[userId];
      if (c == null || !c.devices.any((d) => d.deviceNumber == device)) {
        await refreshContacts();
        c = _contacts[userId];
      }
      b64 = c?.devices.where((d) => d.deviceNumber == device).firstOrNull?.identityKey;
    }
    return b64 == null ? null : base64.decode(b64);
  }

  Future<void> _systemNotice(Map<String, Object?> s) async {
    final event = s['event'] as Map<String, Object?>? ?? const {};
    if (event['type'] == 'user_renamed') {
      final userId = event['userId'] as String?;
      if (userId == null || userId == me) return;
      final from = event['from'] as Map<String, Object?>? ?? const {};
      final to = event['to'] as Map<String, Object?>? ?? const {};
      await _notice(userId, NoticeType.renamed, {
        'from': from['displayName'],
        'to': to['displayName'],
      });
      final chat = await store.chat(userId);
      if (chat != null && to['displayName'] is String) {
        chat.displayName = to['displayName']! as String;
        await store.putChat(chat);
      }
    }
  }

  Future<void> _onDeliveredReceipt(Map<String, Object?> payload) async {
    for (final raw in (payload['messageIds'] as List<Object?>? ?? const [])) {
      final m = await store.message(raw! as String);
      if (m == null || !m.fromMe) continue;
      if (m.status == MessageStatus.sending ||
          m.status == MessageStatus.sent ||
          m.status == MessageStatus.waiting) {
        m.status = MessageStatus.delivered;
        await store.putMessage(m);
      }
    }
    notifyListeners();
  }

  // ------------------------------------------------ reading and receipts

  /// The person opened this chat: clear unread, start disappearing timers,
  /// and (if receipts are on) tell the sender and our own other devices.
  Future<void> markRead(String peer) async {
    final chat = await store.chat(peer);
    if (chat != null && chat.unread > 0) {
      chat.unread = 0;
      await store.putChat(chat);
    }
    final newlyRead = <String>[];
    for (final m in await store.messages(peer, limit: 200)) {
      if (m.fromMe || m.isNotice || m.readAt != null) continue;
      _startTimerOnRead(m);
      await store.putMessage(m);
      newlyRead.add(m.id);
    }
    notifyListeners();
    if (newlyRead.isEmpty) return;
    // With receipts off nothing is sent at all. (Our own other devices then
    // clear this chat's unread count only when it is opened there: syncing
    // read state privately would need a self-addressed route. Known limit.)
    if (!await readReceiptsEnabled()) return;
    try {
      await _post(peer, _uuid.v4(), {'v': 1, 'type': 'read', 'peer': peer, 'ids': newlyRead});
    } on Object {
      // A missed read receipt is harmless.
    }
  }

  void _startTimerOnRead(LocalMessage m) {
    m.readAt ??= DateTime.now();
    if (m.timerSeconds != null) {
      m.expiresAt ??= m.readAt!.add(Duration(seconds: m.timerSeconds!));
    }
  }

  // ------------------------------------------------------------- typing

  DateTime _lastTypingSent = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> typing(String peer) async {
    if (!await typingIndicatorsEnabled()) return;
    final now = DateTime.now();
    if (now.difference(_lastTypingSent) < const Duration(seconds: 4)) return;
    _lastTypingSent = now;
    try {
      final c = _contacts[peer];
      if (c == null) return;
      final bytes = utf8.encode(jsonEncode({'v': 1, 'type': 'typing', 'peer': peer, 'on': true}));
      final envelopes = <Map<String, Object?>>[];
      for (final d in c.devices) {
        // Only to devices we already have a session with: typing never starts one.
        if (!await crypto.hasSession(userId: peer, deviceNumber: d.deviceNumber)) continue;
        final e = await crypto.encrypt(userId: peer, deviceNumber: d.deviceNumber, plaintext: bytes);
        envelopes.add({
          'userId': peer,
          'deviceNumber': d.deviceNumber,
          'kind': e.kind == EnvelopeKind.preKey ? 'prekey' : 'whisper',
          'body': base64.encode(e.body),
        });
      }
      if (envelopes.isEmpty) return;
      await api.post('/users/$peer/signals', {'envelopes': envelopes});
    } on Object {
      // Typing indicators are best effort.
    }
  }

  Future<void> _onSignal(String? from, Map<String, Object?> payload) async {
    if (from == null || from == me || !await typingIndicatorsEnabled()) return;
    final device = payload['fromDevice'] as int?;
    if (device == null) return;
    for (final raw in (payload['envelopes'] as List<Object?>? ?? const [])) {
      final e = raw! as Map<String, Object?>;
      if (e['userId'] != me || e['deviceNumber'] != session.deviceNumber) continue;
      // Only whisper messages on an existing session: a signal never sets one up.
      if (e['kind'] != 'whisper') return;
      try {
        final plain = await crypto.decrypt(
          userId: from,
          deviceNumber: device,
          envelope: Envelope(kind: EnvelopeKind.whisper, body: base64.decode(e['body']! as String)),
        );
        final c = jsonDecode(utf8.decode(plain)) as Map<String, Object?>;
        if (c['type'] == 'typing') {
          _typingUntil[from] = DateTime.now().add(const Duration(seconds: 6));
          notifyListeners();
          Timer(const Duration(seconds: 6, milliseconds: 100), notifyListeners);
        }
      } on Object {
        return;
      }
    }
  }

  // ---------------------------------------------------------- settings

  /// Something in the store changed outside the engine (e.g. a device was
  /// marked verified): tell the screens.
  void changed() => notifyListeners();

  Future<int?> defaultTimer() async => await store.setting('defaultTimer') as int?;

  Future<void> setDefaultTimer(int? seconds) async {
    await store.putSetting('defaultTimer', seconds);
    notifyListeners();
  }

  Future<bool> readReceiptsEnabled() async => (await store.setting('readReceipts') as bool?) ?? true;
  Future<bool> typingIndicatorsEnabled() async => (await store.setting('typing') as bool?) ?? true;

  Future<void> setReadReceipts(bool on) async {
    await store.putSetting('readReceipts', on);
    notifyListeners();
  }

  Future<void> setTypingIndicators(bool on) async {
    await store.putSetting('typing', on);
    notifyListeners();
  }

  // ------------------------------------------------------------ helpers

  Future<ChatSummary> _ensureChat(String peer) async {
    final existing = await store.chat(peer);
    if (existing != null) return existing;
    final c = _contacts[peer];
    final chat = ChatSummary(
      peerUserId: peer,
      displayName: c?.displayName ?? 'Unknown',
      username: c?.username ?? '',
      lastAt: DateTime.now(),
    );
    await store.putChat(chat);
    return chat;
  }

  Future<void> _touchChat(ChatSummary chat, String text, DateTime at, {required bool unread}) async {
    chat
      ..lastText = text
      ..lastAt = at;
    if (unread) chat.unread++;
    await store.putChat(chat);
  }

  Future<void> _notice(String peer, NoticeType type, Map<String, Object?> data) async {
    await _ensureChat(peer);
    await store.putMessage(LocalMessage(
      id: _uuid.v4(),
      peerUserId: peer,
      fromMe: false,
      sentAt: DateTime.now(),
      kind: MessageKind.notice,
      notice: type,
      noticeData: data,
      status: MessageStatus.delivered,
    ));
    notifyListeners();
  }

  /// Deletes messages whose disappearing timer has run out. Gone from the
  /// vault for good (secure_delete); the server never had them.
  Future<void> sweepExpired() async {
    final now = DateTime.now();
    var removed = false;
    for (final chat in await store.chats()) {
      for (final m in await store.messages(chat.peerUserId, limit: 500)) {
        if (m.expiresAt != null && m.expiresAt!.isBefore(now)) {
          await store.deleteMessage(m.id);
          removed = true;
        }
      }
    }
    if (removed) notifyListeners();
  }

  DateTime _lastTopUp = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _topUpKeys() async {
    if (DateTime.now().difference(_lastTopUp) < const Duration(minutes: 10)) return;
    _lastTopUp = DateTime.now();
    try {
      await publishPreKeys(api, crypto);
    } on Object {
      _lastTopUp = DateTime.fromMillisecondsSinceEpoch(0); // try again next sync
    }
  }
}
