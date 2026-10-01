import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../../../core/api/api_client.dart';
import '../../../core/api/session.dart';
import '../../../core/config.dart';
import '../../../core/version.dart';

/// Phase 14c (board 47): the phone's own ringing screen for a call that
/// arrives while Skyline is closed or in the background.
///
/// The push says only "a call, message <id>". This code runs without the key
/// vault (a second copy of the vault could corrupt a session, see push.dart),
/// so it never decrypts anything. It finds out who is calling like this:
/// with a still-valid access token (Skyline was used in the last 15 minutes)
/// it reads that message's sender from the inbox without taking it, and looks
/// the sender up in [CallerNames]. Otherwise it shows "Skyline call"; the name
/// appears once the app opens. It never refreshes the session: the main app
/// might be refreshing at the same moment, and a refresh token works once.
bool get nativeRingingSupported => Platform.isAndroid;

const ringSeconds = 45;

Future<void> ringForPush(String messageId) async {
  if (!nativeRingingSupported) return;
  String? name;
  try {
    name = await _whoIsCalling(messageId).timeout(const Duration(milliseconds: 1500));
  } on Object {
    name = null; // offline, stale token, not found: ring anyway
  }
  await _showNative(id: messageId, name: name ?? 'Skyline call', video: false);
}

/// Board 48, "Like a phone call": a call that arrived while Skyline is open
/// rings on the phone's own call screen too, named from the contact list.
Future<void> ringInApp({required String callId, required String name, required bool video}) async {
  if (!nativeRingingSupported) return;
  try {
    // Already ringing there (its push got in first): leave that one. Accept
    // and Decline act on the call in progress, whichever id it carries.
    if ((await FlutterCallkitIncoming.activeCalls()).isNotEmpty) return;
    await _showNative(id: callId, name: name, video: video);
  } on Object {
    // the app's own screen is still there underneath
  }
}

Future<void> _showNative({required String id, required String name, required bool video}) =>
    FlutterCallkitIncoming.showCallkitIncoming(CallKitParams(
      id: id,
      nameCaller: name,
      appName: 'Skyline',
      handle: '',
      type: video ? 1 : 0,
      duration: ringSeconds * 1000,
      missedCallNotification: const NotificationParams(
        showNotification: true,
        subtitle: 'Missed call',
        isShowCallback: false,
      ),
      extra: {'m': id},
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#0C111C',
        actionColor: '#3A63D8',
        textColor: '#F2F5FA',
        incomingCallNotificationChannelName: 'Incoming calls',
        missedCallNotificationChannelName: 'Missed calls',
        isShowFullLockedScreen: true,
        isImportant: true,
        textAccept: 'Accept',
        textDecline: 'Decline',
      ),
    ));

Future<String?> _whoIsCalling(String messageId) async {
  final session = await SecureSessionStore().read();
  if (session == null || session.accessStale) return null;
  final res = await http.get(
    ApiClient.under(AppConfig.apiBase, '/me/inbox'),
    headers: {'authorization': 'Bearer ${session.accessToken}', 'x-skyline-app': appVersionHeader},
  );
  if (res.statusCode != 200) return null;
  final box = jsonDecode(res.body) as Map<String, Object?>;
  for (final raw in box['envelopes'] as List<Object?>? ?? const []) {
    final e = raw! as Map<String, Object?>;
    if (e['messageId'] == messageId) {
      final sender = e['senderUserId'] as String?;
      return sender == null ? null : (await CallerNames.read())[sender];
    }
  }
  return null;
}

/// Contacts' display names, kept in the OS keystore (not the vault) so the
/// ringing screen can name a caller without opening the vault. Written by the
/// app whenever it refreshes contacts; only names of people you are linked to.
abstract final class CallerNames {
  static final _key = AppConfig.tagged('skyline.caller-names.v1');
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  static Future<Map<String, String>> read() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return const {};
      return (jsonDecode(raw) as Map<String, Object?>).map((k, v) => MapEntry(k, v as String));
    } on Object {
      return const {};
    }
  }

  static Future<void> write(Map<String, String> names) async {
    try {
      await _storage.write(key: _key, value: jsonEncode(names));
    } on Object {
      // best effort: the ringing screen then says "Skyline call"
    }
  }

  static Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } on Object {
      // nothing to do
    }
  }
}

/// The main app's side: when the person answered on the native screen, the
/// app is opened and must take that call as soon as its offer arrives.
class NativeRinging {
  NativeRinging({required this.onAccepted, this.onDeclined});

  /// Called when the person tapped Accept on the phone's ringing screen.
  final void Function() onAccepted;

  /// Called when they tapped Decline there while Skyline was running.
  final void Function()? onDeclined;
  StreamSubscription<CallEvent?>? _sub;

  Future<void> start() async {
    if (!nativeRingingSupported) return;
    _sub = FlutterCallkitIncoming.onEvent.listen((e) {
      if (e is CallEventActionCallAccept) onAccepted();
      if (e is CallEventActionCallDecline) onDeclined?.call();
    });
    // Opened by Accept while Skyline was closed: the event came before we
    // listened, but the call is still listed as accepted.
    try {
      final calls = await FlutterCallkitIncoming.activeCalls();
      if (calls.any((c) => c.isAccepted)) onAccepted();
    } on Object {
      // no native calls
    }
  }

  /// Stops any native ringing or call notification (the app's own call
  /// screen has taken over, or the call is over).
  static Future<void> stopAll() async {
    if (!nativeRingingSupported) return;
    try {
      await FlutterCallkitIncoming.endAllCalls();
    } on Object {
      // nothing ringing
    }
  }

  Future<void> dispose() async => _sub?.cancel();
}
