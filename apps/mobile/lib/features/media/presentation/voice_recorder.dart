import 'dart:async';
import 'dart:io';

import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

/// A finished recording: a plaintext file (deleted once encrypted), its
/// length, and a coarse loudness outline for the bubble (0..31 per bar).
class VoiceClip {
  VoiceClip(this.file, this.durationMs, this.wave);
  final File file;
  final int durationMs;
  final List<int> wave;
}

/// Board 22: records a voice message into [dir] (the short-lived viewing
/// folder, swept at start-up). AAC where the platform has it, else WAV.
class VoiceRecorder {
  VoiceRecorder(this.dir);
  final Directory dir;

  final _rec = AudioRecorder();
  final _watch = Stopwatch();
  final _levels = <double>[];
  StreamSubscription<Amplitude>? _amp;
  String? _path;

  Duration get elapsed => _watch.elapsed;
  bool get recording => _watch.isRunning;

  /// False when the microphone permission is refused.
  Future<bool> start() async {
    if (!await _rec.hasPermission()) return false;
    await dir.create(recursive: true);
    final aac = await _rec.isEncoderSupported(AudioEncoder.aacLc);
    _path = '${dir.path}${Platform.pathSeparator}voice-${const Uuid().v4()}.${aac ? 'm4a' : 'wav'}';
    await _rec.start(
      RecordConfig(
        encoder: aac ? AudioEncoder.aacLc : AudioEncoder.wav,
        bitRate: 64000,
        sampleRate: 44100,
        numChannels: 1,
      ),
      path: _path!,
    );
    _levels.clear();
    _amp = _rec.onAmplitudeChanged(const Duration(milliseconds: 100)).listen((a) => _levels.add(a.current));
    _watch
      ..reset()
      ..start();
    return true;
  }

  /// Stops and returns the clip, or null if it was too short to be meant.
  Future<VoiceClip?> stop() async {
    _watch.stop();
    await _amp?.cancel();
    final path = await _rec.stop() ?? _path;
    final ms = _watch.elapsedMilliseconds;
    if (path == null) return null;
    final file = File(path);
    if (ms < 800) {
      await _delete(file);
      return null;
    }
    return VoiceClip(file, ms, _outline());
  }

  Future<void> cancel() async {
    _watch.stop();
    await _amp?.cancel();
    final path = await _rec.stop() ?? _path;
    if (path != null) await _delete(File(path));
  }

  Future<void> dispose() async {
    if (recording) await cancel();
    await _rec.dispose();
  }

  /// 28 bars from the loudness samples (dBFS, about -60 quiet to 0 loud).
  List<int> _outline() {
    const bars = 28;
    if (_levels.isEmpty) return const [];
    final out = <int>[];
    for (var i = 0; i < bars; i++) {
      final from = (i * _levels.length / bars).floor();
      final to = ((i + 1) * _levels.length / bars).ceil().clamp(from + 1, _levels.length);
      var peak = -160.0;
      for (var j = from; j < to; j++) {
        if (_levels[j] > peak) peak = _levels[j];
      }
      out.add((((peak + 50) / 50) * 31).round().clamp(2, 31));
    }
    return out;
  }

  static Future<void> _delete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } on FileSystemException {
      // swept at start-up
    }
  }
}
