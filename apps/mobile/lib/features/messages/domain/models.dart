/// What the app keeps about conversations. Everything here lives only on the
/// device, sealed in the crypto vault (see LocalStore).
library;

enum MessageStatus { sending, waiting, sent, delivered, read, failed }

enum MessageKind { text, notice }

/// The kinds of notice shown inline in a chat (boards 15-17).
enum NoticeType { newDevice, renamed, blocked, undecryptable, timerChanged }

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
  });

  final String id;
  final String peerUserId;
  final bool fromMe;
  final DateTime sentAt;
  final MessageKind kind;
  final String text;
  MessageStatus status;
  final int? senderDevice;
  final NoticeType? notice;
  final Map<String, Object?> noticeData;
  final int? timerSeconds;
  DateTime? readAt;
  DateTime? expiresAt;

  bool get isNotice => kind == MessageKind.notice;

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
      );
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
  });

  final String peerUserId;
  String displayName;
  String username;
  String lastText;
  DateTime? lastAt;
  int unread;
  int? timerSeconds;

  Map<String, Object?> toJson() => {
        'peer': peerUserId,
        'displayName': displayName,
        'username': username,
        'lastText': lastText,
        'lastAt': lastAt?.millisecondsSinceEpoch,
        'unread': unread,
        'timer': timerSeconds,
      };

  static ChatSummary fromJson(Map<String, Object?> j) => ChatSummary(
        peerUserId: j['peer']! as String,
        displayName: j['displayName']! as String,
        username: j['username']! as String,
        lastText: (j['lastText'] as String?) ?? '',
        lastAt: _time(j['lastAt']),
        unread: (j['unread'] as int?) ?? 0,
        timerSeconds: j['timer'] as int?,
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
