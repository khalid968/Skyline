/// What the app keeps about conversations. Everything here lives only on the
/// device, sealed in the crypto vault (see LocalStore).
library;

enum MessageStatus { sending, waiting, sent, delivered, read, failed }

enum MessageKind { text, notice, media }

/// The kinds of notice shown inline in a chat (boards 15-17).
enum NoticeType { newDevice, renamed, blocked, undecryptable, timerChanged, groupEvent, pinned, call }

class LocalMessage {
  LocalMessage({
    required this.id,
    required this.peerUserId,
    required this.fromMe,
    required this.sentAt,
    this.kind = MessageKind.text,
    this.text = '',
    this.status = MessageStatus.sent,
    this.senderDevice,
    this.notice,
    this.noticeData = const {},
    this.timerSeconds,
    this.readAt,
    this.expiresAt,
    MediaInfo? media,
    List<MediaInfo>? items,
    this.viewOnce = false,
    this.openedAt,
    this.senderUserId,
    this.senderName,
    this.replyTo,
    this.editedAt,
    this.deleted = false,
    Map<String, String>? reactions,
    this.mentions = const [],
  }) : reactions = reactions ?? {},
       items = items ?? [if (media != null) media];

  final String id;
  final String peerUserId;
  final bool fromMe;
  final DateTime sentAt;
  final MessageKind kind;
  String text; // changes when the author edits it (board 28)
  MessageStatus status;
  final int? senderDevice;
  final NoticeType? notice;
  final Map<String, Object?> noticeData;
  final int? timerSeconds;
  DateTime? readAt;
  DateTime? expiresAt;
  /// The files this message carries: one, or an album of up to 10 photos
  /// and videos (board 23).
  final List<MediaInfo> items;

  /// View once (board 24): opened one time, then deleted everywhere.
  final bool viewOnce;

  /// When a view-once message was opened (by them, if we sent it).
  DateTime? openedAt;

  /// Who sent it, in a group (null in a one-to-one chat, where it is the
  /// peer or us). The name is kept as it was, so it survives the sender
  /// leaving the group.
  final String? senderUserId;
  final String? senderName;

  /// Board 28: the message this one answers ({id, name, preview}), a quote.
  final Map<String, Object?>? replyTo;

  /// Set when its author edited it (within 15 minutes of sending).
  DateTime? editedAt;

  /// Deleted for everyone by its author (within 24 hours): what remains is
  /// "This message was deleted".
  bool deleted;

  /// One reaction per person: userId -> emoji.
  final Map<String, String> reactions;

  /// People mentioned in a group message (their user ids).
  final List<String> mentions;

  /// Who wrote it, for authorship checks: us, the group member, or the peer.
  String get author => fromMe ? '' : (senderUserId ?? peerUserId);

  MediaInfo? get media => items.isEmpty ? null : items.first;
  bool get isNotice => kind == MessageKind.notice;
  bool get isMedia => kind == MessageKind.media && items.isNotEmpty;
  bool get isAlbum => items.length > 1;

  /// "Photo", "3 photos", "2 photos and videos", "Photo · view once".
  String get mediaLabel {
    if (items.isEmpty) return '';
    if (items.length == 1) return viewOnce ? '${items.first.label} · view once' : items.first.label;
    final photos = items.where((i) => i.kind == MediaKind.photo).length;
    final videos = items.where((i) => i.kind == MediaKind.video).length;
    if (videos == 0) return '$photos photos';
    if (photos == 0) return '$videos videos';
    return '${items.length} photos and videos';
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'peer': peerUserId,
        'fromMe': fromMe,
        'sentAt': sentAt.millisecondsSinceEpoch,
        'kind': kind.name,
        'text': text,
        'status': status.name,
        'senderDevice': senderDevice,
        'notice': notice?.name,
        'noticeData': noticeData,
        'timer': timerSeconds,
        'readAt': readAt?.millisecondsSinceEpoch,
        'expiresAt': expiresAt?.millisecondsSinceEpoch,
        if (items.isNotEmpty) 'items': [for (final i in items) i.toJson()],
        if (viewOnce) 'viewOnce': true,
        'openedAt': openedAt?.millisecondsSinceEpoch,
        if (senderUserId != null) 'sender': senderUserId,
        if (senderName != null) 'senderName': senderName,
        if (replyTo != null) 'replyTo': replyTo,
        'editedAt': editedAt?.millisecondsSinceEpoch,
        if (deleted) 'deleted': true,
        if (reactions.isNotEmpty) 'reactions': reactions,
        if (mentions.isNotEmpty) 'mentions': mentions,
      };

  static LocalMessage fromJson(Map<String, Object?> j) => LocalMessage(
        id: j['id']! as String,
        peerUserId: j['peer']! as String,
        fromMe: j['fromMe']! as bool,
        sentAt: DateTime.fromMillisecondsSinceEpoch(j['sentAt']! as int),
        kind: MessageKind.values.byName(j['kind']! as String),
        text: (j['text'] as String?) ?? '',
        status: MessageStatus.values.byName(j['status']! as String),
        senderDevice: j['senderDevice'] as int?,
        notice: j['notice'] == null ? null : NoticeType.values.byName(j['notice']! as String),
        noticeData: (j['noticeData'] as Map<String, Object?>?) ?? const {},
        timerSeconds: j['timer'] as int?,
        readAt: _time(j['readAt']),
        expiresAt: _time(j['expiresAt']),
        items: [
          for (final raw in (j['items'] as List<Object?>? ?? [if (j['media'] != null) j['media']]))
            MediaInfo.fromJson(raw! as Map<String, Object?>),
        ],
        viewOnce: j['viewOnce'] == true,
        openedAt: _time(j['openedAt']),
        senderUserId: j['sender'] as String?,
        senderName: j['senderName'] as String?,
        replyTo: j['replyTo'] as Map<String, Object?>?,
        editedAt: _time(j['editedAt']),
        deleted: j['deleted'] == true,
        reactions: {
          for (final e in ((j['reactions'] as Map<String, Object?>?) ?? const {}).entries)
            if (e.value is String) e.key: e.value! as String,
        },
        mentions: [for (final x in (j['mentions'] as List<Object?>? ?? const [])) if (x is String) x],
      );
}

enum MediaKind { photo, video, voice, file }

/// Where a file stands on THIS device.
///  uploading: ours, not yet fully on the server (resumable).
///  remote:    on the server only; photos and voice fetch themselves, the rest on tap.
///  ready:     its ciphertext is on this device (decrypted only while viewed).
///  expired:   the server deleted it (30 days) before this device fetched it.
///  failed:    the upload was refused.
enum MediaState { uploading, remote, ready, expired, failed }

/// One encrypted file riding on a message (decisions.md 2026-09-25). The key,
/// nonce, name, type and thumbnail travel only inside the encrypted message;
/// the server stores an opaque blob under [attachmentId].
class MediaInfo {
  MediaInfo({
    required this.kind,
    required this.name,
    required this.mime,
    required this.size,
    this.attachmentId,
    this.cipherSize = 0,
    this.key = '',
    this.nonce = '',
    this.sha256 = '',
    this.thumb,
    this.width,
    this.height,
    this.durationMs,
    this.wave = const [],
    this.localFile,
    this.state = MediaState.remote,
  });

  final MediaKind kind;
  String name; // may change when a photo is re-encoded before sending
  String mime;
  int size; // plaintext bytes
  String? attachmentId;
  int cipherSize;
  String key; // base64
  String nonce; // base64
  String sha256; // base64, of the ciphertext
  String? thumb; // base64 JPEG, a few KB
  int? width;
  int? height;
  int? durationMs;
  final List<int> wave; // voice: 0..31 per bar
  String? localFile; // file name of the ciphertext in the media folder
  MediaState state;

  /// What travels inside the encrypted message.
  Map<String, Object?> toWire() => {
        'id': attachmentId,
        'kind': kind.name,
        'name': name,
        'mime': mime,
        'size': size,
        'cipherSize': cipherSize,
        'key': key,
        'nonce': nonce,
        'sha256': sha256,
        if (thumb != null) 'thumb': thumb,
        if (width != null) 'w': width,
        if (height != null) 'h': height,
        if (durationMs != null) 'ms': durationMs,
        if (wave.isNotEmpty) 'wave': wave,
      };

  /// A received file; returns null if the sender's JSON is not usable.
  static MediaInfo? fromWire(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final kind = MediaKind.values.where((k) => k.name == raw['kind']).firstOrNull;
    final id = raw['id'];
    if (kind == null || id is! String || raw['key'] is! String || raw['nonce'] is! String) return null;
    return MediaInfo(
      kind: kind,
      name: (raw['name'] as String?) ?? 'file',
      mime: (raw['mime'] as String?) ?? 'application/octet-stream',
      size: (raw['size'] as int?) ?? 0,
      attachmentId: id,
      cipherSize: (raw['cipherSize'] as int?) ?? 0,
      key: raw['key']! as String,
      nonce: raw['nonce']! as String,
      sha256: (raw['sha256'] as String?) ?? '',
      thumb: raw['thumb'] as String?,
      width: raw['w'] as int?,
      height: raw['h'] as int?,
      durationMs: raw['ms'] as int?,
      wave: [for (final x in (raw['wave'] as List<Object?>? ?? const [])) if (x is int) x.clamp(0, 31)],
    );
  }

  Map<String, Object?> toJson() => {
        ...toWire(),
        'localFile': localFile,
        'state': state.name,
      };

  static MediaInfo fromJson(Map<String, Object?> j) {
    final m = MediaInfo.fromWire(j) ??
        MediaInfo(
          kind: MediaKind.values.byName(j['kind']! as String),
          name: (j['name'] as String?) ?? 'file',
          mime: (j['mime'] as String?) ?? 'application/octet-stream',
          size: (j['size'] as int?) ?? 0,
          cipherSize: (j['cipherSize'] as int?) ?? 0,
          key: (j['key'] as String?) ?? '',
          nonce: (j['nonce'] as String?) ?? '',
          sha256: (j['sha256'] as String?) ?? '',
          thumb: j['thumb'] as String?,
          width: j['w'] as int?,
          height: j['h'] as int?,
          durationMs: j['ms'] as int?,
          wave: [for (final x in (j['wave'] as List<Object?>? ?? const [])) if (x is int) x],
        );
    return m
      ..localFile = j['localFile'] as String?
      ..state = MediaState.values.byName((j['state'] as String?) ?? 'remote');
  }

  /// After a view-once message is opened (or sent), nothing that could
  /// decrypt it remains: no key, no local file, no preview.
  void burn() {
    key = '';
    nonce = '';
    thumb = null;
    localFile = null;
  }

  bool get burned => key.isEmpty;

  /// A one-line description, for the chat list and message details.
  String get label => switch (kind) {
        MediaKind.photo => 'Photo',
        MediaKind.video => 'Video',
        MediaKind.voice => 'Voice message',
        MediaKind.file => name,
      };
}

class ChatSummary {
  ChatSummary({
    required this.peerUserId,
    required this.displayName,
    required this.username,
    this.lastText = '',
    this.lastAt,
    this.unread = 0,
    this.timerSeconds,
    this.isGroup = false,
    this.left = false,
    List<String>? pins,
    this.mentioned = false,
  }) : pins = pins ?? [];

  final String peerUserId;
  String displayName;
  String username;
  String lastText;
  DateTime? lastAt;
  int unread;
  int? timerSeconds;

  /// A group chat: [peerUserId] is then the group's id.
  final bool isGroup;

  /// We left the group, or were removed, or it was archived: history stays,
  /// writing does not.
  bool left;

  /// Pinned message ids, oldest first, at most 3 (board 27).
  final List<String> pins;

  /// Someone mentioned us in a message we have not read yet ("@" in the list).
  bool mentioned;

  Map<String, Object?> toJson() => {
        'peer': peerUserId,
        'displayName': displayName,
        'username': username,
        'lastText': lastText,
        'lastAt': lastAt?.millisecondsSinceEpoch,
        'unread': unread,
        'timer': timerSeconds,
        if (isGroup) 'group': true,
        if (left) 'left': true,
        if (pins.isNotEmpty) 'pins': pins,
        if (mentioned) 'mentioned': true,
      };

  static ChatSummary fromJson(Map<String, Object?> j) => ChatSummary(
        peerUserId: j['peer']! as String,
        displayName: j['displayName']! as String,
        username: j['username']! as String,
        lastText: (j['lastText'] as String?) ?? '',
        lastAt: _time(j['lastAt']),
        unread: (j['unread'] as int?) ?? 0,
        timerSeconds: j['timer'] as int?,
        isGroup: j['group'] == true,
        left: j['left'] == true,
        pins: [for (final x in (j['pins'] as List<Object?>? ?? const [])) if (x is String) x],
        mentioned: j['mentioned'] == true,
      );
}

/// A device of a contact (or of ours) as this device has seen it.
class KnownDevice {
  KnownDevice({
    required this.userId,
    required this.deviceNumber,
    required this.identityKey,
    required this.firstSeen,
    this.verifiedAt,
    this.platform,
  });

  final String userId;
  final int deviceNumber;
  final String identityKey; // base64
  final DateTime firstSeen;
  DateTime? verifiedAt;
  final String? platform;

  String get key => '$userId:$deviceNumber';

  Map<String, Object?> toJson() => {
        'userId': userId,
        'deviceNumber': deviceNumber,
        'identityKey': identityKey,
        'firstSeen': firstSeen.millisecondsSinceEpoch,
        'verifiedAt': verifiedAt?.millisecondsSinceEpoch,
        'platform': platform,
      };

  static KnownDevice fromJson(Map<String, Object?> j) => KnownDevice(
        userId: j['userId']! as String,
        deviceNumber: j['deviceNumber']! as int,
        identityKey: j['identityKey']! as String,
        firstSeen: DateTime.fromMillisecondsSinceEpoch(j['firstSeen']! as int),
        verifiedAt: _time(j['verifiedAt']),
        platform: j['platform'] as String?,
      );
}

DateTime? _time(Object? v) => v == null ? null : DateTime.fromMillisecondsSinceEpoch(v as int);
