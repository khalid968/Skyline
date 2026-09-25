import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/session.dart';
import '../../../core/crypto/device_crypto.dart';
import '../../../core/realtime/realtime_client.dart';
import '../../auth/data/prekeys.dart';
import '../../media/data/media_service.dart';
import '../domain/models.dart';
import 'local_store.dart';

part 'messenger_groups.dart';
part 'messenger_actions.dart';

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
///   {"v":1,"type":"media","id","peer","body","sentAt","timer","once","items":[{...}]}
///       body is the caption; each item holds one file's key, nonce, hash,
///       name, type and preview (MediaInfo.toWire); several items make an
///       album (board 23); once marks view-once (board 24). The server has
///       only the blobs.
///   {"v":1,"type":"opened","peer","ids":[...]}     a view-once was opened
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
    required this.media,
  });

  final ApiClient api;
  final CryptoDevice crypto;
  final LocalStore store;
  final RealtimeClient realtime;
  final Session session;
  final MediaService media;

  final _uuid = const Uuid();
  final Map<String, Contact> _contacts = {};
  final Map<int, String> _ownIdentities = {}; // our other devices
  final Map<String, Group> _groups = {};
  final Map<String, DateTime> _typingUntil = {};
  final Map<String, String> _typingWho = {}; // group id -> who is typing
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
  Group? group(String groupId) => _groups[groupId];
  List<Group> get groups => _groups.values.toList();
  bool isTyping(String peer) => (_typingUntil[peer]?.isAfter(DateTime.now())) ?? false;

  /// In a group, who is typing (their first name).
  String? typingName(String peer) => isTyping(peer) ? _typingWho[peer] : null;

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
    unawaited(refreshGroups().catchError((Object _) {}));
    unawaited(_topUpKeys());
    unawaited(media.sweepViewCache());
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

  /// The chat a new message goes into. The first message in a new chat
  /// carries this person's default timer (board 13), announced like any
  /// timer change.
  Future<ChatSummary> _chatForSending(String peer) async {
    final isNew = await store.chat(peer) == null ||
        (await store.messages(peer, limit: 1)).isEmpty;
    final fallback = await defaultTimer();
    if (isNew && fallback != null && (await store.chat(peer))?.timerSeconds == null) {
      await setTimer(peer, fallback);
    }
    return _ensureChat(peer);
  }

  Future<LocalMessage> sendText(String peer, String text,
      {Map<String, Object?>? replyTo, List<String> mentions = const []}) async {
    final chat = await _chatForSending(peer);
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
      replyTo: replyTo,
      mentions: mentions,
    );
    await store.putMessage(m);
    await _touchChat(chat, chat.isGroup ? 'You: $text' : text, now, unread: false);
    notifyListeners();
    await _deliver(m, _contentFor(m));
    return m;
  }

  /// Sends one file (boards 20-22). See [sendFiles].
  Future<LocalMessage> sendMedia(
    String peer,
    File source,
    MediaKind kind, {
    String caption = '',
    String? name,
    String? mime,
    int? durationMs,
    List<int> wave = const [],
    bool deleteSource = false,
    bool viewOnce = false,
  }) async =>
      (await sendFiles(
        peer,
        [
          OutgoingFile(source, kind,
              name: name, mime: mime, durationMs: durationMs, wave: wave, temporary: deleteSource),
        ],
        caption: caption,
        viewOnce: viewOnce,
      ))
          .single;

  /// Sends several files at once (board 23). Photos and videos go together
  /// as one album (up to 10) carrying the caption; documents and voice
  /// messages each go as their own message. Every file has its own key.
  /// [viewOnce] (board 24) applies to a single photo or video.
  ///
  /// Each message shows at once with its progress; files are prepared
  /// (compressed), encrypted on this device, uploaded in resumable parts,
  /// then announced in one encrypted message that carries their keys.
  Future<List<LocalMessage>> sendFiles(
    String peer,
    List<OutgoingFile> files, {
    String caption = '',
    bool viewOnce = false,
  }) async {
    if (files.isEmpty) return const [];
    if (files.length > maxFilesPerSend) throw ArgumentError('Up to $maxFilesPerSend files at a time.');
    for (final f in files) {
      if (await f.file.length() > MediaService.maxBytes) throw ArgumentError('Files can be up to 2 GB.');
    }
    final visual = [for (final f in files) if (f.kind == MediaKind.photo || f.kind == MediaKind.video) f];
    final others = [for (final f in files) if (f.kind != MediaKind.photo && f.kind != MediaKind.video) f];
    final once = viewOnce && visual.length == 1 && others.isEmpty;
    final groups = <(List<OutgoingFile>, String)>[
      if (visual.isNotEmpty) (visual, caption),
      for (var i = 0; i < others.length; i++) ([others[i]], visual.isEmpty && i == 0 ? caption : ''),
    ];
    final chat = await _chatForSending(peer);
    final messages = <LocalMessage>[];
    // All of them appear at once, in order; the work then runs one by one.
    for (final (group, text) in groups) {
      final now = DateTime.now();
      final m = LocalMessage(
        id: _uuid.v4(),
        peerUserId: peer,
        fromMe: true,
        sentAt: now,
        kind: MessageKind.media,
        text: text,
        status: MessageStatus.sending,
        senderDevice: session.deviceNumber,
        timerSeconds: chat.timerSeconds,
        expiresAt: chat.timerSeconds == null ? null : now.add(Duration(seconds: chat.timerSeconds!)),
        viewOnce: once,
        items: [
          for (final f in group)
            MediaInfo(
              kind: f.kind,
              name: f.name ?? f.file.uri.pathSegments.last,
              mime: f.mime ?? mimeFor(f.name ?? f.file.uri.pathSegments.last, f.kind),
              size: await f.file.length(),
              durationMs: f.durationMs,
              wave: f.wave,
              state: MediaState.uploading,
            ),
        ],
      );
      await store.putMessage(m);
      await _touchChat(chat, _preview(m), now, unread: false);
      messages.add(m);
    }
    notifyListeners();
    for (var g = 0; g < groups.length; g++) {
      await _prepareAndSend(messages[g], groups[g].$1);
    }
    return messages;
  }

  static const maxFilesPerSend = 10;

  Future<void> _prepareAndSend(LocalMessage m, List<OutgoingFile> files) async {
    try {
      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        final info = m.items[i];
        PreparedFile? prepared;
        try {
          prepared = await media.prepare(transferKey(m.id, i), f.file, f.kind, info.name);
          info
            ..name = prepared.name
            ..mime = f.mime ?? mimeFor(prepared.name, f.kind)
            ..size = await prepared.file.length()
            ..thumb = prepared.thumb ?? info.thumb
            ..width = prepared.width ?? info.width
            ..height = prepared.height ?? info.height
            ..durationMs = f.durationMs ?? prepared.durationMs;
          if (info.size > MediaService.maxBytes) throw ArgumentError('Files can be up to 2 GB.');
          await store.putMessage(m);
          notifyListeners();
          await media.encrypt(transferKey(m.id, i), prepared.file, info);
        } finally {
          for (final gone in [
            if (f.temporary) f.file,
            if (prepared != null && prepared.temporary && prepared.file.path != f.file.path) prepared.file,
          ]) {
            try {
              await gone.delete();
            } on FileSystemException {
              // already gone
            }
          }
        }
      }
      await _fitPreviews(m);
    } on Object {
      for (final info in m.items) {
        if (info.state == MediaState.uploading && info.key.isEmpty) info.state = MediaState.failed;
      }
      m.status = MessageStatus.failed;
      await store.putMessage(m);
      for (var i = 0; i < m.items.length; i++) {
        media.finished(transferKey(m.id, i));
      }
      notifyListeners();
      return;
    }
    await store.putMessage(m);
    await _uploadAndDeliver(m);
  }

  /// Progress is tracked per file: message id plus position in the album.
  static String transferKey(String messageId, int index) => '$messageId:$index';

  /// Previews travel inside the encrypted message, which has to stay small
  /// (the server takes 48 KB per copy). A view-once message carries none at
  /// all: a preview would outlive the one viewing. An album keeps small
  /// previews for the four tiles it shows.
  Future<void> _fitPreviews(LocalMessage m) async {
    if (m.viewOnce) {
      for (final i in m.items) {
        i.thumb = null;
      }
      return;
    }
    if (!m.isAlbum) return;
    for (var i = 0; i < m.items.length; i++) {
      final item = m.items[i];
      if (item.thumb == null) continue;
      item.thumb = i < 4 ? await MediaService.shrinkPreview(item.thumb!, 6000) : null;
    }
  }

  /// Uploads (or resumes uploading) a message's files, then sends the message.
  Future<void> _uploadAndDeliver(LocalMessage m) async {
    for (var i = 0; i < m.items.length; i++) {
      final info = m.items[i];
      if (info.state != MediaState.uploading) continue;
      try {
        await media.upload(transferKey(m.id, i), info, onStarted: () => store.putMessage(m));
        info.state = MediaState.ready;
        await store.putMessage(m);
      } on Object catch (e) {
        if (e is SignedOutException) signedOut = true;
        m.status = e is ApiException && e.offline ? MessageStatus.waiting : MessageStatus.failed;
        await store.putMessage(m);
        for (var j = 0; j < m.items.length; j++) {
          media.finished(transferKey(m.id, j));
        }
        notifyListeners();
        return;
      } finally {
        media.finished(transferKey(m.id, i));
      }
    }
    await _deliver(m, _contentFor(m));
    // A view-once message we sent: once it is out, we cannot open it either.
    if (m.viewOnce && m.fromMe && m.status == MessageStatus.sent) await _burn(m);
  }

  /// Forgets everything that could decrypt a view-once message on this
  /// device: the key, the preview and the downloaded ciphertext.
  Future<void> _burn(LocalMessage m) async {
    for (final info in m.items) {
      await media.delete(info);
      info.burn();
    }
    await store.putMessage(m);
    notifyListeners();
  }

  /// Fetches a received file's ciphertext. Photos and voice messages do this
  /// by themselves; videos and documents when tapped.
  Future<void> fetchMedia(String messageId, [int index = 0]) async {
    final m = await store.message(messageId);
    if (m == null || index >= m.items.length) return;
    final info = m.items[index];
    if (info.state != MediaState.remote || info.attachmentId == null || info.burned) return;
    MediaState? next;
    try {
      await media.download(transferKey(m.id, index), info);
      next = MediaState.ready;
    } on MediaExpiredException {
      next = MediaState.expired;
    } on SignedOutException {
      signedOut = true;
    } on Object {
      // Offline or interrupted: the partial file stays and the next try resumes.
    }
    if (next != null) {
      final state = next;
      // Several files of one album can finish together: each update reads
      // and writes the message in turn, so none is lost.
      await _serially(messageId, () async {
        final fresh = await store.message(messageId);
        if (fresh == null || fresh.items.length <= index || fresh.items[index].burned) {
          await media.delete(info); // it disappeared, or was opened elsewhere, meanwhile
        } else {
          fresh.items[index]
            ..localFile = state == MediaState.ready ? '${info.attachmentId}.enc' : null
            ..state = state;
          await store.putMessage(fresh);
        }
      });
    }
    notifyListeners();
  }

  final Map<String, Future<void>> _messageLocks = {};

  /// Runs [update] after any other update of the same message has finished.
  Future<void> _serially(String messageId, Future<void> Function() update) {
    final previous = _messageLocks[messageId] ?? Future<void>.value();
    final next = previous.then((_) => update());
    final settled = next.catchError((Object _) {});
    _messageLocks[messageId] = settled;
    unawaited(settled.whenComplete(() {
      if (identical(_messageLocks[messageId], settled)) _messageLocks.remove(messageId);
    }));
    return next;
  }

  /// A view-once message was opened here and closed (board 24): it is gone
  /// from this device, and we tell the sender and our own other devices,
  /// which delete their copies too. This notice goes even with read receipts
  /// off, because it is what removes the message from our other devices.
  Future<void> viewOnceOpened(String messageId) async {
    final m = await store.message(messageId);
    if (m == null || !m.viewOnce || m.fromMe) return;
    m.openedAt ??= DateTime.now();
    await _burn(m);
    if (!await _sendOpened(m.peerUserId, [m.id])) {
      // Offline: queued, and sent on reconnect (see _flushOutbox).
      final queue = [...?(await store.setting('openedOutbox') as List<Object?>?)];
      queue.add({'peer': m.peerUserId, 'id': m.id});
      await store.putSetting('openedOutbox', queue);
    }
  }

  Future<bool> _sendOpened(String peer, List<String> ids) async {
    try {
      await _post(peer, _uuid.v4(), {'v': 1, 'type': 'opened', 'peer': peer, 'ids': ids});
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> _flushOpened() async {
    final queue = (await store.setting('openedOutbox') as List<Object?>?) ?? const [];
    if (queue.isEmpty) return;
    final left = <Object?>[];
    for (final raw in queue) {
      final e = raw! as Map<String, Object?>;
      if (!await _sendOpened(e['peer']! as String, [e['id']! as String])) left.add(e);
    }
    await store.putSetting('openedOutbox', left);
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
    if (m.items.any((i) => i.state == MediaState.failed)) return; // never encrypted: nothing to send
    m.status = MessageStatus.sending;
    await store.putMessage(m);
    notifyListeners();
    await (m.isMedia ? _uploadAndDeliver(m) : _deliver(m, _contentFor(m)));
  }

  Map<String, Object?> _contentFor(LocalMessage m) => m.isMedia
      ? {
          'v': 1,
          'type': 'media',
          'id': m.id,
          'peer': m.peerUserId,
          'body': m.text,
          'sentAt': m.sentAt.millisecondsSinceEpoch,
          'timer': m.timerSeconds,
          if (m.viewOnce) 'once': true,
          'items': [for (final i in m.items) i.toWire()],
        }
      : m.isNotice
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
          if (m.replyTo != null) 'reply': m.replyTo,
          if (m.mentions.isNotEmpty) 'mentions': m.mentions,
        };

  /// Encrypts [content] for every device and posts it. Offline: the message
  /// waits (board 19) and goes out on reconnect. Refused by the protocol
  /// (e.g. a changed identity): it fails, visibly.
  Future<void> _deliver(LocalMessage m, Map<String, Object?> content) async {
    try {
      final attachments = m.isMedia ? [for (final i in m.items) i.attachmentId!] : null;
      if (await _isGroup(m.peerUserId)) {
        await _postGroup(m.peerUserId, m.id, content, attachmentIds: attachments);
      } else {
        await _post(m.peerUserId, m.id, content, attachmentIds: attachments);
      }
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
  Future<void> _post(String peer, String messageId, Map<String, Object?> content,
      {List<String>? attachmentIds}) async {
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
        await api.post('/users/$peer/messages', {
          'messageId': messageId,
          'envelopes': envelopes,
          if (attachmentIds != null) 'attachmentIds': attachmentIds,
        });
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
    await _flushOpened();
    await _flushControl();
    for (final chat in await store.chats()) {
      for (final m in await store.messages(chat.peerUserId, limit: 200)) {
        if (m.fromMe && m.status == MessageStatus.waiting) {
          m.status = MessageStatus.sending;
          await (m.isMedia ? _uploadAndDeliver(m) : _deliver(m, _contentFor(m)));
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
    if (e['kind'] == 'sender_key') return _receiveGroup(e);
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
      // Refused: never shown, never opened. Board 17's red notice (in the
      // group, for a key share from a member who is not a contact).
      final groupId = e['groupId'] as String?;
      final peer = fromMe ? null : (groupId ?? sender);
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
    if (content['type'] == 'skey') return _acceptSenderKey(sender, device, content);
    // The chat: from a contact it is the sender; from our own other device it
    // is whoever that device addressed.
    final peer = fromMe ? content['peer'] as String? : sender;
    if (peer == null) return;
    await _handleContent(peer, sender, device, content);
  }

  /// One decrypted message, one-to-one ([group] false: [peer] is the other
  /// person) or in a group ([peer] is the group id, [sender] who wrote it).
  Future<void> _handleContent(String peer, String sender, int device, Map<String, Object?> content,
      {bool group = false}) async {
    final fromMe = sender == me;
    final senderName = group && !fromMe ? (_groups[peer]?.member(sender)?.displayName ?? 'Someone') : null;
    final sentAt = DateTime.fromMillisecondsSinceEpoch(
      (content['sentAt'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
    );

    switch (content['type']) {
      case 'text' || 'media':
        final id = content['id']! as String;
        if (await store.message(id) != null) return; // already have it
        final timer = content['timer'] as int?;
        final isMedia = content['type'] == 'media';
        final items = [
          for (final raw in (content['items'] as List<Object?>? ?? [if (content['media'] != null) content['media']]))
            MediaInfo.fromWire(raw),
        ];
        if (isMedia && (items.isEmpty || items.length > maxFilesPerSend || items.contains(null))) return;
        final viewOnce = isMedia && content['once'] == true && items.length == 1;
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
          kind: isMedia ? MessageKind.media : MessageKind.text,
          items: [for (final i in items) i!],
          viewOnce: viewOnce && !group, // view once is one-to-one only
          senderUserId: group ? sender : null,
          senderName: senderName,
          replyTo: _quoteFrom(content['reply']),
          mentions: group ? [for (final x in (content['mentions'] as List<Object?>? ?? const [])) if (x is String) x] : const [],
        );
        // Our own view-once, sent from another of our devices: we cannot
        // open it here either.
        if (viewOnce && fromMe) {
          for (final i in m.items) {
            i.burn();
          }
        }
        await store.putMessage(m);
        final chat = await _ensureChat(peer);
        final line = !group ? _preview(m) : '${fromMe ? 'You' : senderName!.split(' ').first}: ${_preview(m)}';
        if (!fromMe && openChat != peer && m.mentions.contains(me)) chat.mentioned = true;
        await _touchChat(chat, line, sentAt, unread: !fromMe && openChat != peer);
        if (!fromMe) _typingUntil.remove(peer);
        if (!fromMe && openChat == peer) unawaited(markRead(peer));
        for (var i = 0; i < m.items.length; i++) {
          final item = m.items[i];
          if (!item.burned && (item.kind == MediaKind.photo || item.kind == MediaKind.voice)) {
            unawaited(fetchMedia(m.id, i));
          }
        }
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
          noticeData: {'seconds': seconds, 'byMe': fromMe, if (senderName != null) 'name': senderName},
          status: MessageStatus.delivered,
        ));
      case 'edit' || 'delete' || 'react' || 'pin':
        await _applyControl(peer, sender, content, senderName: senderName);
      case 'opened':
        // A view-once was opened: by them (we sent it), or on one of our
        // other devices (it was sent to us). Either way it is gone here.
        for (final raw in (content['ids'] as List<Object?>? ?? const [])) {
          if (raw is! String) continue;
          final m = await store.message(raw);
          if (m == null || !m.viewOnce || m.peerUserId != peer) continue; // only this chat's
          if (m.fromMe == fromMe) continue; // only the other side's opening counts
          m.openedAt ??= DateTime.now();
          await _burn(m);
        }
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
      String? lookup() =>
          _contacts[userId]?.devices.where((d) => d.deviceNumber == device).firstOrNull?.identityKey ??
          [
            for (final g in _groups.values)
              ...?g.member(userId)?.devices.where((d) => d.deviceNumber == device),
          ].firstOrNull?.identityKey;
      b64 = lookup();
      if (b64 == null) {
        // A member we share a group with but no link (their key shares come
        // pairwise too), or a device we have not seen yet.
        await refreshContacts().catchError((Object _) {});
        await refreshGroups().catchError((Object _) {});
        b64 = lookup();
      }
    }
    return b64 == null ? null : base64.decode(b64);
  }

  Future<void> _systemNotice(Map<String, Object?> s) async {
    final event = s['event'] as Map<String, Object?>? ?? const {};
    final groupId = s['groupId'] as String?;
    if (groupId != null && (event['type'] as String? ?? '').startsWith('group_')) {
      return _groupNotice(groupId, event);
    }
    if (groupId != null && event['type'] == 'user_renamed') {
      // A member renamed by an administrator, announced in the group (they
      // may not be a contact of ours at all).
      final from = event['from'] as Map<String, Object?>? ?? const {};
      final to = event['to'] as Map<String, Object?>? ?? const {};
      if (event['userId'] == me) return;
      await _notice(groupId, NoticeType.renamed, {'from': from['displayName'], 'to': to['displayName']});
      return;
    }
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
    if (chat != null && (chat.unread > 0 || chat.mentioned)) {
      chat
        ..unread = 0
        ..mentioned = false;
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
    if (await _isGroup(peer)) return; // groups send no read receipts (8b)
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
      final g = _groups[peer];
      final c = _contacts[peer];
      if (g == null && c == null) return;
      final bytes = utf8.encode(jsonEncode({'v': 1, 'type': 'typing', 'peer': peer, 'on': true, 'group': g != null}));
      // A group: every other member's devices. One to one: the contact's.
      final targets = g != null
          ? [
              for (final t in _groupTargets(g))
                if (t.$1 != me) t,
            ]
          : [for (final d in c!.devices) (peer, d.deviceNumber)];
      final envelopes = <Map<String, Object?>>[];
      for (final t in targets) {
        // Only to devices we already have a session with: typing never starts one.
        if (!await crypto.hasSession(userId: t.$1, deviceNumber: t.$2)) continue;
        final e = await crypto.encrypt(userId: t.$1, deviceNumber: t.$2, plaintext: bytes);
        envelopes.add({
          'userId': t.$1,
          'deviceNumber': t.$2,
          'kind': e.kind == EnvelopeKind.preKey ? 'prekey' : 'whisper',
          'body': base64.encode(e.body),
        });
      }
      if (envelopes.isEmpty) return;
      await api.post(g != null ? '/groups/$peer/signals' : '/users/$peer/signals', {'envelopes': envelopes});
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
        final groupId = payload['groupId'] as String?;
        if (c['type'] == 'typing' && groupId != null) {
          // Typing in a group: only if it really is that group, and they are in it.
          if (c['peer'] != groupId || _groups[groupId]?.member(from) == null) return;
          _typingUntil[groupId] = DateTime.now().add(const Duration(seconds: 6));
          _typingWho[groupId] = _groups[groupId]!.member(from)!.displayName.split(' ').first;
          notifyListeners();
          Timer(const Duration(seconds: 6, milliseconds: 100), notifyListeners);
        } else if (c['type'] == 'typing') {
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

  /// Mute (boards 26 and 29), kept on this device only. A muted chat still
  /// syncs; it just stays quiet.
  Future<bool> isMuted(String peer) async => (await store.setting('muted:$peer') as bool?) ?? false;

  Future<void> setMuted(String peer, bool on) async {
    await store.putSetting('muted:$peer', on);
    notifyListeners();
  }

  /// Archive (board 26), this device only. An archived chat comes back when
  /// someone writes, unless it is muted.
  Future<bool> isArchived(String peer) async => (await store.setting('archived:$peer') as bool?) ?? false;

  Future<void> setArchived(String peer, bool on) async {
    await store.putSetting('archived:$peer', on);
    notifyListeners();
  }

  /// Drafts (board 26): a half-written message, kept in the vault per chat.
  Future<String?> draft(String peer) async {
    final d = await store.setting('draft:$peer') as String?;
    return d == null || d.trim().isEmpty ? null : d;
  }

  Future<void> saveDraft(String peer, String text) =>
      store.putSetting('draft:$peer', text.trim().isEmpty ? null : text);

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
    final g = _groups[peer];
    final chat = ChatSummary(
      peerUserId: peer,
      displayName: g?.name ?? c?.displayName ?? 'Unknown',
      username: c?.username ?? '',
      lastAt: DateTime.now(),
      isGroup: g != null,
    );
    await store.putChat(chat);
    return chat;
  }

  Future<void> _touchChat(ChatSummary chat, String text, DateTime at, {required bool unread}) async {
    chat
      ..lastText = text
      ..lastAt = at;
    if (unread) {
      chat.unread++;
      // Someone wrote: an archived chat comes back, unless muted (board 26).
      if (await isArchived(chat.peerUserId) && !await isMuted(chat.peerUserId)) {
        await store.putSetting('archived:${chat.peerUserId}', false);
      }
    }
    await store.putChat(chat);
  }

  /// A reply's quote, as received: only plain fields, trimmed.
  Map<String, Object?>? _quoteFrom(Object? raw) {
    if (raw is! Map<String, Object?> || raw['id'] is! String) return null;
    final preview = (raw['preview'] as String?) ?? '';
    return {
      'id': raw['id'],
      if (raw['author'] is String) 'author': raw['author'],
      if (raw['name'] is String) 'name': raw['name'],
      'preview': preview.length > 200 ? '${preview.substring(0, 200)}…' : preview,
    };
  }

  Future<bool> _isGroup(String peer) async =>
      _isGroupChat(peer) || ((await store.chat(peer))?.isGroup ?? false);

  /// The chat list's one-line summary of a message.
  String _preview(LocalMessage m) =>
      !m.isMedia ? m.text : (m.text.isEmpty ? m.mediaLabel : '${m.mediaLabel} · ${m.text}');

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
          for (final i in m.items) {
            await media.delete(i);
          }
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

/// A file to send (board 23). [temporary] files are plaintext copies we made
/// (a recording, a camera shot, a phone picker's copy), deleted once
/// encrypted.
class OutgoingFile {
  OutgoingFile(this.file, this.kind,
      {this.name, this.mime, this.durationMs, this.wave = const [], this.temporary = false});
  final File file;
  final MediaKind kind;
  final String? name;
  final String? mime;
  final int? durationMs;
  final List<int> wave;
  final bool temporary;
}

/// A reasonable content type from a file name, for the receiving app.
String mimeFor(String name, MediaKind kind) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'heic' => 'image/heic',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    'webm' => 'video/webm',
    'm4a' => 'audio/mp4',
    'aac' => 'audio/aac',
    'wav' => 'audio/wav',
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    'doc' => 'application/msword',
    'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'zip' => 'application/zip',
    _ => switch (kind) {
        MediaKind.photo => 'image/jpeg',
        MediaKind.video => 'video/mp4',
        MediaKind.voice => 'audio/mp4',
        MediaKind.file => 'application/octet-stream',
      },
  };
}
