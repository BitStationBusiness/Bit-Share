import 'dart:convert';
import 'dart:io';

/// The tools Bit-Share ships beside its own executable so a release never
/// depends on anything installed globally on the destination computer.
class WindowsRuntimePaths {
  const WindowsRuntimePaths({
    required this.ytDlp,
    required this.ffmpeg,
    required this.ffprobe,
    this.deno,
  });

  final String ytDlp;
  final String ffmpeg;
  final String ffprobe;
  final String? deno;
}

class WindowsRuntimeException implements Exception {
  const WindowsRuntimeException(this.message);

  final String message;

  @override
  String toString() => message;
}

const _missingRuntimeMessage =
    'Falta el motor multimedia de Windows. Ejecuta '
    'tools/setup_windows_runtime.ps1 y vuelve a compilar.';

WindowsRuntimePaths? _cached;

/// Where every Bit-Share download lands, and therefore what the gallery
/// lists. Shared by the download backend and the gallery so the two can
/// never drift apart.
String windowsLibraryDirectory() {
  return joinPath(
    Platform.environment['USERPROFILE'] ?? Directory.current.path,
    'Downloads',
    'Bit-Share',
  );
}

/// Finds the bundled runtime, preferring the copy next to the running
/// executable and falling back to the source tree during development. The
/// result is cached because it cannot change while the app is running.
Future<WindowsRuntimePaths> resolveWindowsRuntime() async {
  final cached = _cached;
  if (cached != null) return cached;

  final executableDirectory = File(Platform.resolvedExecutable).parent.path;
  final candidates = <String>[
    joinPath(executableDirectory, 'runtime'),
    joinPath(Directory.current.path, 'windows', 'runtime'),
    joinPath(Directory.current.path, 'runtime'),
  ];
  for (final directory in candidates) {
    final ytDlp = File(joinPath(directory, 'yt-dlp.exe'));
    final ffmpeg = File(joinPath(directory, 'ffmpeg.exe'));
    if (await ytDlp.exists() && await ffmpeg.exists()) {
      final deno = File(joinPath(directory, 'deno.exe'));
      final ffprobe = File(joinPath(directory, 'ffprobe.exe'));
      return _cached = WindowsRuntimePaths(
        ytDlp: ytDlp.path,
        ffmpeg: ffmpeg.path,
        // A runtime prepared before ffprobe was bundled still downloads
        // fine; only the gallery's metadata probe degrades, so this resolves
        // to the name on PATH rather than failing the whole app.
        ffprobe: await ffprobe.exists() ? ffprobe.path : 'ffprobe.exe',
        deno: await deno.exists() ? deno.path : null,
      );
    }
  }

  if (await commandExists('yt-dlp.exe') && await commandExists('ffmpeg.exe')) {
    return _cached = const WindowsRuntimePaths(
      ytDlp: 'yt-dlp.exe',
      ffmpeg: 'ffmpeg.exe',
      ffprobe: 'ffprobe.exe',
    );
  }
  throw const WindowsRuntimeException(_missingRuntimeMessage);
}

Future<bool> commandExists(String executable) async {
  try {
    final result = await Process.run(
      'where.exe',
      [executable],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

String joinPath(
  String first,
  String second, [
  String? third,
  String? fourth,
  String? fifth,
]) {
  final separator = Platform.pathSeparator;
  final values = [first, second, ?third, ?fourth, ?fifth];
  return values
      .map((value) => value.replaceAll(RegExp(r'[\\/]+$'), ''))
      .join(separator);
}
