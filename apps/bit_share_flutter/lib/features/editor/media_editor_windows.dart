import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/media_formatting.dart';
import '../../core/windows_runtime.dart';
import '../gallery/media_item.dart';
import '../gallery/media_library_windows.dart';
import 'ffmpeg_plan.dart';
import 'media_editor.dart';

class WindowsMediaEditor implements MediaEditor {
  WindowsMediaEditor({String? directory, WindowsMediaLibrary? library})
    : _directory = directory ?? windowsLibraryDirectory(),
      _library = library ?? WindowsMediaLibrary(directory: directory);

  final String _directory;
  final WindowsMediaLibrary _library;
  Process? _activeProcess;
  bool _cancelled = false;

  @override
  Future<MediaItem> probe(MediaItem item) async {
    if (item.duration != null) return item;
    // The library already knows how to read metadata; re-listing is cheaper
    // than duplicating the ffprobe call and keeps one parser in play.
    final snapshot = await _library.load();
    return snapshot.items.where((entry) => entry.id == item.id).firstOrNull ??
        item;
  }

  @override
  Future<MediaItem> export(
    MediaEditRequest request, {
    required void Function(double progress) onProgress,
  }) async {
    if (_activeProcess != null) {
      throw const MediaEditException('Ya hay una exportación en curso.');
    }
    _cancelled = false;

    final WindowsRuntimePaths runtime;
    try {
      runtime = await resolveWindowsRuntime();
    } on WindowsRuntimeException catch (error) {
      throw MediaEditException(error.message);
    }

    final extension = editOutputExtension(request);
    final output = await _uniqueOutputPath(request.source, extension);
    final plan = buildFfmpegEditPlan(
      request: request,
      inputPath: request.source.uri,
      outputPath: output,
    );

    final process = await Process.start(runtime.ffmpeg, plan.arguments);
    _activeProcess = process;

    final errors = StringBuffer();
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final progress = _progressFrom(line, plan.expectedDuration);
          if (progress != null) onProgress(progress);
        })
        .asFuture<void>();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (errors.length < 16384) errors.writeln(line);
        })
        .asFuture<void>();

    try {
      final exitCode = await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      if (_cancelled) {
        await _deleteQuietly(output);
        throw const MediaEditCancelled();
      }
      if (exitCode != 0) {
        await _deleteQuietly(output);
        throw MediaEditException(_friendlyFailure(errors.toString()));
      }
      final file = File(output);
      if (!await file.exists() || await file.length() == 0) {
        await _deleteQuietly(output);
        throw const MediaEditException(
          'La exportación terminó sin producir un archivo.',
        );
      }
      onProgress(1);
      final snapshot = await _library.load();
      return snapshot.items
              .where((entry) => entry.id == file.absolute.path)
              .firstOrNull ??
          MediaItem(
            id: file.absolute.path,
            name: _fileName(output),
            uri: file.absolute.path,
            path: file.absolute.path,
            kind: request.source.kind,
            mimeType: request.source.mimeType,
            sizeBytes: await file.length(),
            duration: plan.expectedDuration,
            modifiedAt: DateTime.now(),
          );
    } finally {
      if (identical(_activeProcess, process)) _activeProcess = null;
    }
  }

  @override
  Future<void> cancel() async {
    final process = _activeProcess;
    if (process == null) return;
    _cancelled = true;
    await Process.run(
      'taskkill.exe',
      ['/PID', '${process.pid}', '/T', '/F'],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  }

  /// ffmpeg writes `key=value` lines when started with `-progress`. Only the
  /// output timestamp is interesting; everything else is ignored.
  double? _progressFrom(String line, Duration expected) {
    if (expected <= Duration.zero) return null;
    final separator = line.indexOf('=');
    if (separator <= 0) return null;
    final key = line.substring(0, separator).trim();
    final value = line.substring(separator + 1).trim();
    if (key != 'out_time') return null;
    final position = parseFfmpegTimestamp(value);
    if (position == null) return null;
    return (position.inMicroseconds / expected.inMicroseconds).clamp(0.0, 1.0);
  }

  /// Edits are saved alongside the original rather than over it, so a bad
  /// trim never destroys the download it came from.
  Future<String> _uniqueOutputPath(MediaItem source, String extension) async {
    await Directory(_directory).create(recursive: true);
    final base = _sanitize(source.baseName);
    var candidate = joinPath(_directory, '$base (editado).$extension');
    var attempt = 2;
    while (await File(candidate).exists()) {
      candidate = joinPath(_directory, '$base (editado $attempt).$extension');
      attempt++;
    }
    return candidate;
  }

  /// Windows rejects these characters in a file name. Source names come from
  /// yt-dlp's `--windows-filenames`, so this is belt and braces for edits of
  /// files that arrived some other way.
  static String _sanitize(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .trim();
    return cleaned.isEmpty ? 'Bit-Share' : cleaned;
  }

  static String _fileName(String path) {
    final separator = path.lastIndexOf(RegExp(r'[\\/]'));
    return separator < 0 ? path : path.substring(separator + 1);
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // The partial file is already gone or locked; nothing useful to do.
    }
  }

  static String _friendlyFailure(String rawError) {
    final error = rawError.toLowerCase();
    if (error.contains('no space left')) {
      return 'No hay espacio suficiente para guardar el archivo editado.';
    }
    if (error.contains('permission denied') || error.contains('access is denied')) {
      return 'Windows no permitió escribir en la carpeta de Bit-Share.';
    }
    if (error.contains('invalid data') || error.contains('moov atom not found')) {
      return 'El archivo original está dañado y no se puede editar.';
    }
    return 'No se pudo procesar la edición.';
  }
}
