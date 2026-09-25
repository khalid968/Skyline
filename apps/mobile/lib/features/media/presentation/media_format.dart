/// "5.0 MB", "184 MB", "812 KB".
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  final mb = bytes / (1024 * 1024);
  if (mb < 10) return '${mb.toStringAsFixed(1)} MB';
  if (mb < 1024) return '${mb.round()} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

/// "3.1 of 5.0 MB": both numbers in the larger one's unit.
String formatProgress(int done, int total) {
  final big = total >= 1024 * 1024;
  String n(int b) => big
      ? (total / (1024 * 1024) < 10 ? (b / (1024 * 1024)).toStringAsFixed(1) : (b / (1024 * 1024)).round().toString())
      : (b / 1024).round().toString();
  return '${n(done)} of ${n(total)} ${big ? 'MB' : 'KB'}';
}

/// "2:41", "0:07".
String formatDuration(int? ms) {
  if (ms == null) return '';
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
