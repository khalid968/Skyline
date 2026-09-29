import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../features/calls/data/ringer.dart';
import '../../features/messages/data/messenger.dart';
import '../api/api_client.dart';

/// Push wake-ups (decisions.md, Phase 8). Google delivers a message that
/// contains nothing but "something new" ({"t":"inbox"}).
///
/// - App open: the wake-up just triggers a pull (the socket usually got there
///   first).
/// - App in the background or closed: Android runs [onBackgroundWakeUp] in a
///   separate isolate. It shows a notice that says only "New message" and
///   touches nothing else: decrypting there would open the key vault from a
///   second isolate, and two ratchet updates at once could corrupt a session.
///   The message is pulled and decrypted when the app is next opened.
///
/// Android only for now. iOS needs an Apple developer account (APNs); Windows
/// stays connected by socket while the app runs.
bool get pushSupported => !kIsWeb && Platform.isAndroid;

final _notices = FlutterLocalNotificationsPlugin();
const _channel = AndroidNotificationChannel(
  'messages',
  'Messages',
  description: 'New messages. The notice never shows who wrote or what.',
  importance: Importance.high,
);

Future<void> _initNotices() async {
  await _notices.initialize(
    settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
  );
  await _notices
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(_channel);
}

Future<void> _showNewMessage() => _notices.show(
      id: 0, // one notice, replaced, however many arrive
      title: 'Skyline',
      body: 'New message',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.high,
          priority: Priority.high,
          // Nothing private is in it, but keep it off the lock screen anyway.
          visibility: NotificationVisibility.private,
        ),
      ),
    );

@pragma('vm:entry-point')
Future<void> onBackgroundWakeUp(RemoteMessage message) async {
  // Phase 14c: a call rings on the phone's own screen (ringer.dart).
  if (message.data['t'] == 'call' && message.data['m'] is String) {
    await ringForPush(message.data['m'] as String);
    return;
  }
  if (message.data['t'] != 'inbox') return;
  await _initNotices();
  await _showNewMessage();
}

/// Called once at start-up, before runApp.
Future<void> initPush() async {
  if (!pushSupported) return;
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(onBackgroundWakeUp);
  await _initNotices();
}

/// Registers this device's token with the Skyline server and keeps it fresh.
class PushRegistrar {
  PushRegistrar({required this.api, required this.messenger});

  final ApiClient api;
  final Messenger messenger;
  final List<StreamSubscription<Object?>> _subs = [];

  Future<void> start() async {
    if (!pushSupported) return;
    try {
      final fm = FirebaseMessaging.instance;
      // Android 13+: may show the system prompt. Refusing only hides the
      // notice; the wake-up (and so the pull) still works.
      final perm = await fm.requestPermission();
      final token = await fm.getToken();
      lastStatus = 'permission ${perm.authorizationStatus.name}, token ${token == null ? 'none' : 'received'}';
      if (token != null) await _register(token);
      _subs
        ..add(fm.onTokenRefresh.listen((t) => unawaited(_register(t))))
        // Foreground: just pull; no notice (the chat list updates itself).
        ..add(FirebaseMessaging.onMessage.listen((_) => unawaited(messenger.sync())))
        // The person tapped a notice: pull right away.
        ..add(FirebaseMessaging.onMessageOpenedApp.listen((_) => unawaited(messenger.sync())));
    } on Object catch (e) {
      lastStatus = 'unavailable: $e';
      debugPrint('push $lastStatus');
    }
  }

  /// What happened on the last start, for diagnostics (never contains the token).
  String lastStatus = 'not started';

  Future<void> _register(String token) async {
    try {
      await api.put('/me/push', {'provider': 'fcm', 'token': token});
      lastStatus += ', registered';
    } on Object catch (e) {
      lastStatus += ', registration failed: $e'; // retried on the next start
    }
  }

  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }
}
