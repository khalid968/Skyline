import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config.dart';

/// Who this device is on the server, and its current tokens. Kept in the OS
/// keystore beside the vault key, never in plain app storage.
class Session {
  const Session({
    required this.userId,
    required this.deviceId,
    required this.deviceNumber,
    required this.accessToken,
    required this.accessExpiresAt,
    required this.refreshToken,
  });

  final String userId;
  final String deviceId;
  final int deviceNumber;
  final String accessToken;
  final DateTime accessExpiresAt;
  final String refreshToken;

  bool get accessStale =>
      DateTime.now().isAfter(accessExpiresAt.subtract(const Duration(seconds: 30)));

  Session withTokens({
    required String accessToken,
    required DateTime accessExpiresAt,
    required String refreshToken,
  }) =>
      Session(
        userId: userId,
        deviceId: deviceId,
        deviceNumber: deviceNumber,
        accessToken: accessToken,
        accessExpiresAt: accessExpiresAt,
        refreshToken: refreshToken,
      );

  Map<String, Object?> toJson() => {
        'userId': userId,
        'deviceId': deviceId,
        'deviceNumber': deviceNumber,
        'accessToken': accessToken,
        'accessExpiresAt': accessExpiresAt.toIso8601String(),
        'refreshToken': refreshToken,
      };

  static Session fromJson(Map<String, Object?> j) => Session(
        userId: j['userId']! as String,
        deviceId: j['deviceId']! as String,
        deviceNumber: j['deviceNumber']! as int,
        accessToken: j['accessToken']! as String,
        accessExpiresAt: DateTime.parse(j['accessExpiresAt']! as String),
        refreshToken: j['refreshToken']! as String,
      );
}

abstract class SessionStore {
  Future<Session?> read();
  Future<void> write(Session s);
  Future<void> clear();
}

class SecureSessionStore implements SessionStore {
  SecureSessionStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  static final _name = AppConfig.tagged('skyline.session.v1');
  final FlutterSecureStorage _storage;

  @override
  Future<Session?> read() async {
    final raw = await _storage.read(key: _name);
    return raw == null ? null : Session.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  @override
  Future<void> write(Session s) => _storage.write(key: _name, value: jsonEncode(s.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _name);
}

class MemorySessionStore implements SessionStore {
  Session? session;
  @override
  Future<Session?> read() async => session;
  @override
  Future<void> write(Session s) async => session = s;
  @override
  Future<void> clear() async => session = null;
}
