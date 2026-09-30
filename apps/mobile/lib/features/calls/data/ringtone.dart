import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

/// Sound and vibration while a call rings on Skyline's own call screen (the
/// app is open). Noticeable, not annoying:
///
/// - Android: the phone's own ringtone at the ring volume and a gentle
///   vibration, following the ringer mode (silent: nothing; vibrate: only
///   vibration). Native side: Ringer.kt.
/// - iPhone: a soft chime Skyline generated itself (assets/sounds/ring.wav),
///   muted by the ring/silent switch, with a light vibration each round.
/// - Windows: the same chime at a moderate volume.
///
/// Always stopped on answer, decline, or when the call stops ringing. A closed
/// app rings through the phone's native call screen instead (ringer.dart).
class Ringtone {
  static const _channel = MethodChannel('skyline/ringer');
  AudioPlayer? _player;
  Timer? _buzz;
  bool _on = false;

  Future<void> start() async {
    if (_on) return;
    _on = true;
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod<void>('start');
        return;
      }
      final player = _player ??= AudioPlayer();
      await player.setAudioContext(AudioContext(
        // Ambient: the iPhone's silent switch mutes it, and other audio is
        // not stopped for it.
        iOS: AudioContextIOS(category: AVAudioSessionCategory.ambient),
      ));
      await player.setReleaseMode(ReleaseMode.loop);
      await player.setVolume(0.55);
      await player.play(AssetSource('sounds/ring.wav'));
      if (Platform.isIOS) {
        unawaited(HapticFeedback.vibrate());
        _buzz = Timer.periodic(const Duration(milliseconds: 2700), (_) => HapticFeedback.vibrate());
      }
    } on Object {
      // No sound is better than a call that cannot be answered.
    }
  }

  Future<void> stop() async {
    if (!_on) return;
    _on = false;
    _buzz?.cancel();
    _buzz = null;
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod<void>('stop');
      } else {
        await _player?.stop();
      }
    } on Object {
      // already quiet
    }
  }

  Future<void> dispose() async {
    await stop();
    await _player?.dispose();
    _player = null;
  }
}
