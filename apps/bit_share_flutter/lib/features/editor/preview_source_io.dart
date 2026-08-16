import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/windows_runtime.dart';
import '../gallery/media_item.dart';
import 'preview_policy.dart';
import 'preview_source_model.dart';

/// Builds a lightweight Windows-only H.264 proxy when Media Foundation would
/// otherwise decode the source at a visibly reduced frame rate. FFmpeg keeps
/// the source timestamps and frame cadence; only preview resolution/codec are
/// changed. Android continues to open the original content URI directly.
Future<EditorPreviewSource> prepareEditorPreview(MediaItem item) async {
  if (!Platform.isWindows ||
      item.kind != MediaKind.video ||
      item.path == null) {
    return EditorPreviewSource(uri: item.uri, path: item.path);
  }

  try {
    final runtime = await resolveWindowsRuntime();
    final codec = await _videoCodec(runtime.ffprobe, item.path!);
    if (!requiresOptimizedWindowsPreview(codec)) {
      return EditorPreviewSource(uri: item.uri, path: item.path);
    }

    final source = File(item.path!);
    final stat = await source.stat();
    final identity =
        '${source.absolute.path}|${stat.size}|'
        '${stat.modified.millisecondsSinceEpoch}';
    final key = sha256.convert(utf8.encode(identity)).toString();
    final cache = Directory(
      joinPath(Directory.systemTemp.path, 'Bit-Share', 'editor-preview'),
    );
    await cache.create(recursive: true);
    final output = File(joinPath(cache.path, '$key.mp4'));
    if (!await output.exists() || await output.length() == 0) {
      final partial = File(joinPath(cache.path, '$key.partial.mp4'));
      if (await partial.exists()) await partial.delete();
      final result = await Process.run(runtime.ffmpeg, [
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-i',
        source.path,
        '-map',
        '0:v:0',
        '-map',
        '0:a:0?',
        '-vf',
        r'scale=-2:min(720\,ih)',
        '-c:v',
        'libx264',
        '-preset',
        'ultrafast',
        '-crf',
        '24',
        '-pix_fmt',
        'yuv420p',
        '-fps_mode',
        'passthrough',
        '-c:a',
        'aac',
        '-b:a',
        '128k',
        '-movflags',
        '+faststart',
        partial.path,
      ]);
      if (result.exitCode != 0 || !await partial.exists()) {
        if (await partial.exists()) await partial.delete();
        return EditorPreviewSource(uri: item.uri, path: item.path);
      }
      await partial.rename(output.path);
    }
    unawaited(_cleanOldPreviews(cache, except: output.path));
    return EditorPreviewSource(
      uri: output.path,
      path: output.path,
      optimized: true,
    );
  } catch (_) {
    // Preview optimization is opportunistic. Editing must remain available
    // even if the runtime or cache is temporarily unavailable.
    return EditorPreviewSource(uri: item.uri, path: item.path);
  }
}

Future<String?> _videoCodec(String ffprobe, String path) async {
  final result = await Process.run(ffprobe, [
    '-v',
    'error',
    '-select_streams',
    'v:0',
    '-show_entries',
    'stream=codec_name',
    '-of',
    'default=noprint_wrappers=1:nokey=1',
    path,
  ]);
  if (result.exitCode != 0) return null;
  return result.stdout.toString().trim().toLowerCase();
}

Future<void> _cleanOldPreviews(
  Directory directory, {
  required String except,
}) async {
  final cutoff = DateTime.now().subtract(const Duration(days: 3));
  await for (final entity in directory.list()) {
    if (entity is! File || entity.path == except) continue;
    try {
      final stat = await entity.stat();
      if (stat.modified.isBefore(cutoff)) await entity.delete();
    } on FileSystemException {
      // Another Bit-Share process can still be using this cache entry.
    }
  }
}
