/// Presentation helpers shared by the gallery, the viewer and the editor so
/// a size or a timestamp reads identically everywhere in the app.
library;

String formatBytes(int bytes) {
  const gib = 1024 * 1024 * 1024;
  const mib = 1024 * 1024;
  if (bytes >= gib) return '${(bytes / gib).toStringAsFixed(1)} GB';
  if (bytes >= mib) return '${(bytes / mib).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

/// `m:ss` for anything under an hour, `h:mm:ss` beyond it — the clock format
/// a player is expected to show, not a zero-padded duration.
String formatDuration(Duration duration) {
  final total = duration.isNegative ? Duration.zero : duration;
  final hours = total.inHours;
  final minutes = total.inMinutes.remainder(60);
  final seconds = total.inSeconds.remainder(60);
  final paddedSeconds = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$paddedSeconds';
  }
  return '$minutes:$paddedSeconds';
}

/// The `HH:MM:SS.mmm` form ffmpeg accepts for `-ss` and `-t`. Always padded
/// and always with milliseconds, because ffmpeg reads a bare `1:30` as
/// 1 minute 30 seconds only in some positions and as seconds in others.
String formatFfmpegTimestamp(Duration duration) {
  final total = duration.isNegative ? Duration.zero : duration;
  final hours = total.inHours.toString().padLeft(2, '0');
  final minutes = total.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = total.inSeconds.remainder(60).toString().padLeft(2, '0');
  final millis = total.inMilliseconds.remainder(1000).toString().padLeft(
    3,
    '0',
  );
  return '$hours:$minutes:$seconds.$millis';
}

/// Parses the `out_time=HH:MM:SS.microseconds` line ffmpeg writes when it is
/// started with `-progress`. Returns null for anything else, including the
/// `N/A` ffmpeg emits before the first frame is muxed.
Duration? parseFfmpegTimestamp(String value) {
  final trimmed = value.trim();
  final match = RegExp(
    r'^(\d+):([0-5]?\d):([0-5]?\d)(?:\.(\d+))?$',
  ).firstMatch(trimmed);
  if (match == null) return null;
  final fraction = match.group(4) ?? '';
  // ffmpeg writes six fractional digits; anything shorter or longer is
  // normalised to microseconds rather than silently misread by 1000x.
  final microseconds = fraction.isEmpty
      ? 0
      : (double.parse('0.$fraction') * Duration.microsecondsPerSecond).round();
  return Duration(
    hours: int.parse(match.group(1)!),
    minutes: int.parse(match.group(2)!),
    seconds: int.parse(match.group(3)!),
    microseconds: microseconds,
  );
}
