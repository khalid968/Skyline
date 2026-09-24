import 'dart:convert';
import 'dart:io';

import '../../../core/api/api_client.dart';
import '../../../core/api/session.dart';
import '../../../core/crypto/device_crypto.dart';
import 'prekeys.dart';

/// Why activation failed, in the words the screen shows.
enum ActivationError { rejected, offline, rateLimited, unknown }

class ActivationFailure implements Exception {
  ActivationFailure(this.error);
  final ActivationError error;
}

/// Turns an administrator's one-time code into an activated device (board 1).
///
/// The device's keys already exist (they are created with the vault). The
/// activation request carries the PUBLIC identity key and registration id,
/// covered by an Ed25519 signature from the device credential, so the server
/// learns exactly which identity this device chose (activation v2).
class ActivationService {
  ActivationService({required this.api, required this.crypto, required this.sessions});

  final ApiClient api;
  final CryptoDevice crypto;
  final SessionStore sessions;

  Future<Session> activate({required String code, required String deviceName}) async {
    final normalized = normalizeCode(code);
    if (normalized == null) throw ActivationFailure(ActivationError.rejected);

    final id = await crypto.identity();
    final identityB64 = base64.encode(id.identityKey);
    final signature = await crypto.sign(
      message: utf8.encode('skyline-activate:v2:$normalized:$identityB64:${id.registrationId}'),
    );

    Map<String, Object?> r;
    try {
      r = await api.postPublic('/auth/activate', {
        'code': normalized,
        'deviceName': deviceName.trim(),
        'platform': _platform(),
        'signingKey': base64.encode(id.signingKey),
        'identityKey': identityB64,
        'registrationId': id.registrationId,
        'signature': base64.encode(signature),
      }) as Map<String, Object?>;
    } on ApiException catch (e) {
      if (e.offline) throw ActivationFailure(ActivationError.offline);
      if (e.status == 401 || e.status == 400) throw ActivationFailure(ActivationError.rejected);
      if (e.status == 429) throw ActivationFailure(ActivationError.rateLimited);
      throw ActivationFailure(ActivationError.unknown);
    }

    final session = Session(
      userId: r['userId']! as String,
      deviceId: r['deviceId']! as String,
      deviceNumber: r['deviceNumber']! as int,
      accessToken: r['accessToken']! as String,
      accessExpiresAt: DateTime.parse(r['accessExpiresAt']! as String),
      refreshToken: r['refreshToken']! as String,
    );
    await sessions.write(session);
    await crypto.setLocalAddress(userId: session.userId, deviceNumber: session.deviceNumber);
    // The code is spent now, so a failed key upload must not strand the
    // device: the messenger publishes whatever is missing on its first sync.
    try {
      await publishPreKeys(api, crypto);
    } on Object {
      // Repaired by the next sync.
    }
    return session;
  }

  static String _platform() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    return 'linux';
  }

  static const _crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// Mirrors the server: any case, spaces or dashes, the SKY prefix optional,
  /// O read as 0 and I/L as 1. Returns the 20 canonical characters or null.
  static String? normalizeCode(String input) {
    var s = input.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    if (s.length == 23 && s.startsWith('SKY')) s = s.substring(3);
    s = s.replaceAll('O', '0').replaceAll(RegExp('[IL]'), '1');
    if (s.length != 20) return null;
    for (final ch in s.split('')) {
      if (!_crockford.contains(ch)) return null;
    }
    return s;
  }
}
