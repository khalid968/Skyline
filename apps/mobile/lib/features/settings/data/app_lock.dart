import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:local_auth/local_auth.dart';

import '../../../core/crypto/device_crypto.dart';
import '../../messages/data/local_store.dart';

/// App lock (boards 13 and 14): always the person's own choice, never an
/// administrator's (owner decision 2026-09-21). The PIN is an Argon2id hash in
/// the vault; biometrics are the operating system's (face, fingerprint,
/// Windows Hello) and never leave the device. Wrong PINs back off in the core,
/// so closing the app does not reset the count.
class AppLock extends ChangeNotifier with WidgetsBindingObserver {
  AppLock({required this.crypto, required this.store, LocalAuthentication? auth})
      : _auth = auth ?? LocalAuthentication();

  final CryptoDevice crypto;
  final LocalStore store;
  final LocalAuthentication _auth;

  bool enabled = false;
  bool biometrics = false;
  bool biometricsAvailable = false;
  int lockAfterSeconds = 60;
  bool locked = false;
  DateTime? _wentAway;

  static const lockAfterChoices = <(String, int)>[
    ('Immediately', 0),
    ('1 minute', 60),
    ('5 minutes', 300),
    ('30 minutes', 1800),
  ];

  Future<void> load() async {
    enabled = await crypto.hasAppLockPin();
    biometrics = (await store.setting('lockBiometrics') as bool?) ?? false;
    lockAfterSeconds = (await store.setting('lockAfter') as int?) ?? 60;
    try {
      biometricsAvailable = await _auth.canCheckBiometrics && await _auth.isDeviceSupported();
    } on Object {
      biometricsAvailable = false;
    }
    locked = enabled; // a cold start is always locked when the lock is on
    WidgetsBinding.instance.addObserver(this);
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!enabled) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _wentAway ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final away = _wentAway;
      _wentAway = null;
      if (away != null && DateTime.now().difference(away).inSeconds >= lockAfterSeconds) {
        locked = true;
        notifyListeners();
      }
    }
  }

  /// Returns the seconds to wait before another try (0 on success or a plain
  /// miss). Unlocks on success.
  Future<({bool ok, int wait})> tryPin(String pin) async {
    final r = await crypto.checkAppLockPin(pin: pin);
    if (r.ok) {
      locked = false;
      notifyListeners();
    }
    return (ok: r.ok, wait: r.waitSeconds);
  }

  Future<bool> tryBiometrics() async {
    if (!biometrics || !biometricsAvailable) return false;
    try {
      final ok = await _auth.authenticate(
        localizedReason: 'Unlock Skyline',
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
      if (ok) {
        locked = false;
        notifyListeners();
      }
      return ok;
    } on Object {
      return false;
    }
  }

  Future<void> enable(String pin) async {
    await crypto.setAppLockPin(pin: pin);
    enabled = true;
    notifyListeners();
  }

  Future<void> disable() async {
    await crypto.clearAppLockPin();
    enabled = false;
    locked = false;
    notifyListeners();
  }

  Future<void> setBiometrics(bool on) async {
    if (on) {
      // Prove it works (and that it is the owner) before relying on it.
      bool ok;
      try {
        ok = await _auth.authenticate(localizedReason: 'Use biometrics to unlock Skyline', biometricOnly: true);
      } on Object {
        ok = false;
      }
      if (!ok) return;
    }
    biometrics = on;
    await store.putSetting('lockBiometrics', on);
    notifyListeners();
  }

  Future<void> setLockAfter(int seconds) async {
    lockAfterSeconds = seconds;
    await store.putSetting('lockAfter', seconds);
    notifyListeners();
  }
}
