import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../../core/media_formatting.dart';
import '../../core/windows_runtime.dart';
import 'media_library.dart';

/// Reads the Bit-Share download folder directly. Windows has no media index
/// to query, so metadata comes from ffprobe and is cached on disk — probing
/// every file on every refresh would make the grid visibly slow once a user
/// has a few dozen downloads.
class WindowsMediaLibrary implements MediaLibrary {
  WindowsMediaLibrary({String? directory, MethodChannel? nativeChannel})
    : _directory = directory ?? windowsLibraryDirectory(),
      _nativeChannel =
          nativeChannel ?? const MethodChannel('bitshare/windows');

  /// How many ffprobe processes may run at once. Enough to hide the per-probe
  /// startup cost without flooding a laptop's CPU on a large library.
  static const _probeConcurrency = 4;

  final String _directory;
  final MethodChannel _nativeChannel;
  Map<String, Object?>? _metadataCache;

  @override
  String get storageLocationLabel => _directory;

  @override
  bool get canShare => false;

  @override
  bool get canRevealInFileManager => true;

  @override
  bool get canCopyToClipboard => true;

  String get _supportDirectory => joinPath(
    Platform.environment['LOCALAPPDATA'] ?? Directory.current.path,
    'Bit-Share',
    'gallery',
  );

  String get _thumbnailDirectory => joinPath(_supportDirectory, 'thumbnails');

  File get _metadataFile => File(joinPath(_supportDirectory, 'metadata.json'));

  @override
  Future<MediaLibrarySnapshot> load() async {
    final directory = Directory(_directory);
    if (!await directory.exists()) return MediaLibrarySnapshot.empty;

    final files = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = _fileName(entity.path);
      if (name.startsWith('.') || name.endsWith('.part')) continue;
      final kind = MediaKind.kindForExtension(name);
      final extension = _extensionOf(name);
      final known =
          MediaKind.videoExtensions.contains(extension) ||
          MediaKind.audioExtensions.contains(extension) ||
          MediaKind.imageExtensions.contains(extension);
      if (!known) continue;
      if (kind == MediaKind.image &&
          !MediaKind.imageExtensions.contains(extension)) {
        continue;
      }
      files.add(entity);
    }

    final cache = await _loadMetadataCache();
    var cacheChanged = false;
    final items = List<MediaItem?>.filled(files.length, null);

    // Probing runs in fixed-size waves rather than all at once: a library of
    // a hundred files would otherwise spawn a hundred ffprobe processes.
    for (var offset = 0; offset < files.length; offset += _probeConcurrency) {
      final end = (offset + _probeConcurrency).clamp(0, files.length);
      await Future.wait([
        for (var index = offset; index < end; index++)
          () async {
            final file = files[index];
            final stat = await file.stat();
            final key = _cacheKey(file.path, stat);
            var metadata = cache[key];
            if (metadata is! Map) {
              metadata = await _probeFile(file.path);
              cache[key] = metadata;
              cacheChanged = true;
            }
            items[index] = _itemFor(
              file.path,
              stat,
              Map<Object?, Object?>.from(metadata),
            );
          }(),
      ]);
    }

    if (cacheChanged) await _saveMetadataCache(cache);

    final resolved = items.whereType<MediaItem>().toList()
      ..sort((left, right) {
        final leftDate = left.modifiedAt;
        final rightDate = right.modifiedAt;
        if (leftDate == null || rightDate == null) {
          return left.name.compareTo(right.name);
        }
        return rightDate.compareTo(leftDate);
      });
    return MediaLibrarySnapshot(items: resolved);
  }

  @override
  Future<bool> requestAccess() async => true;

  @override
  Future<String?> thumbnailPath(MediaItem item) async {
    final file = File(item.uri);
    if (!await file.exists()) return null;
    final stat = await file.stat();
    final digest = sha1.convert(utf8.encode(_cacheKey(item.uri, stat)));
    final target = File(joinPath(_thumbnailDirectory, '$digest.jpg'));
    if (await target.exists() && await target.length() > 0) return target.path;

    await Directory(_thumbnailDirectory).create(recursive: true);
    final WindowsRuntimePaths runtime;
    try {
      runtime = await resolveWindowsRuntime();
    } on WindowsRuntimeException {
      return null;
    }

    final arguments = item.kind == MediaKind.audio
        ? _coverArtArguments(item, target.path)
        : _posterFrameArguments(item, target.path);
    try {
      final result = await Process.run(
        runtime.ffmpeg,
        arguments,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (result.exitCode != 0) return null;
    } on ProcessException {
      return null;
    }
    if (!await target.exists() || await target.length() == 0) return null;
    return target.path;
  }

  /// Audio thumbnails are whatever cover art is embedded in the file; there
  /// is no frame to grab, so a track without art simply has no thumbnail.
  List<String> _coverArtArguments(MediaItem item, String output) {
    return [
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-i',
      item.uri,
      '-an',
      '-frames:v',
      '1',
      '-f',
      'image2',
      output,
    ];
  }

  List<String> _posterFrameArguments(MediaItem item, String output) {
    // A tenth of the way in avoids the black or logo frame many clips open
    // on, while staying inside even a very short video.
    final duration = item.duration;
    final seek = duration == null
        ? Duration.zero
        : Duration(
            milliseconds: (duration.inMilliseconds ~/ 10).clamp(0, 3000),
          );
    return [
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      if (seek > Duration.zero) ...['-ss', formatFfmpegTimestamp(seek)],
      '-i',
      item.uri,
      '-frames:v',
      '1',
      '-vf',
      _thumbnailScaleFilter(item),
      '-f',
      'image2',
      output,
    ];
  }

  /// Fits the frame inside a 640px box. Exact dimensions are computed when
  /// the source size is known so the result is always even-sided; otherwise
  /// ffmpeg is asked to work it out with an expression.
  String _thumbnailScaleFilter(MediaItem item) {
    const box = 640;
    final width = item.width;
    final height = item.height;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return "scale='if(gt(iw,ih),$box,-2)':'if(gt(iw,ih),-2,$box)'";
    }
    final longest = width > height ? width : height;
    if (longest <= box) return 'scale=$width:$height';
    final factor = box / longest;
    return 'scale=${_even(width * factor)}:${_even(height * factor)}';
  }

  @override
  Future<int> delete(Iterable<MediaItem> items) async {
    var deleted = 0;
    for (final item in items) {
      final file = File(item.uri);
      try {
        if (await file.exists()) {
          await file.delete();
          deleted++;
        }
      } on FileSystemException catch (error) {
        throw MediaLibraryException(
          'No se pudo borrar "${item.name}": ${error.osError?.message ?? 'archivo en uso'}.',
        );
      }
    }
    return deleted;
  }

  @override
  Future<bool> share(MediaItem item) async {
    throw UnsupportedError('Windows no expone un menú Compartir del sistema.');
  }

  @override
  Future<void> revealInFileManager(MediaItem item) async {
    // `explorer /select,<path>` opens the folder with the file highlighted.
    // It reports a non-zero exit code even when it succeeds, so the result is
    // deliberately not checked.
    await Process.start('explorer.exe', [
      '/select,${item.uri}',
    ], mode: ProcessStartMode.detached);
  }

  @override
  Future<void> copyToClipboard(MediaItem item) async {
    try {
      final copied = await _nativeChannel.invokeMethod<bool>('copyFile', {
        'path': item.uri,
      });
      if (copied != true) {
        throw const MediaLibraryException(
          'No se pudo copiar el archivo al portapapeles.',
        );
      }
    } on PlatformException catch (error) {
      throw MediaLibraryException(
        error.message ?? 'No se pudo copiar el archivo al portapapeles.',
      );
    }
  }

  MediaItem _itemFor(
    String path,
    FileStat stat,
    Map<Object?, Object?> metadata,
  ) {
    final name = _fileName(path);
    final durationMs = (metadata['durationMs'] as num?)?.toInt();
    return MediaItem(
      id: path,
      name: name,
      uri: path,
      path: path,
      kind: MediaKind.kindForExtension(name),
      mimeType: metadata['mimeType'] as String? ?? '',
      sizeBytes: stat.size,
      duration: durationMs == null || durationMs <= 0
          ? null
          : Duration(milliseconds: durationMs),
      modifiedAt: stat.modified,
      width: (metadata['width'] as num?)?.toInt(),
      height: (metadata['height'] as num?)?.toInt(),
    );
  }

  /// Reads duration and frame size with ffprobe. Failure is not fatal: the
  /// file is still listed and playable, it just shows no duration badge.
  Future<Map<String, Object?>> _probeFile(String path) async {
    final WindowsRuntimePaths runtime;
    try {
      runtime = await resolveWindowsRuntime();
    } on WindowsRuntimeException {
      return const {};
    }
    try {
      final result = await Process.run(
        runtime.ffprobe,
        [
          '-v',
          'error',
          '-print_format',
          'json',
          '-show_entries',
          'format=duration:stream=width,height,codec_type',
          path,
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (result.exitCode != 0) return const {};
      final decoded = jsonDecode(result.stdout.toString());
      if (decoded is! Map) return const {};
      return _metadataFromProbe(Map<String, Object?>.from(decoded));
    } on ProcessException {
      return const {};
    } on FormatException {
      return const {};
    }
  }

  static Map<String, Object?> _metadataFromProbe(Map<String, Object?> probe) {
    final format = probe['format'];
    final seconds = format is Map
        ? double.tryParse('${(format)['duration']}')
        : null;
    final streams = (probe['streams'] as List? ?? const [])
        .whereType<Map>()
        .map((stream) => Map<String, Object?>.from(stream))
        .toList(growable: false);
    final video = streams
        .where((stream) => stream['codec_type'] == 'video')
        .firstOrNull;
    return {
      if (seconds != null && seconds > 0)
        'durationMs': (seconds * 1000).round(),
      if (video != null) ...{
        'width': (video['width'] as num?)?.toInt(),
        'height': (video['height'] as num?)?.toInt(),
      },
    };
  }

  Future<Map<String, Object?>> _loadMetadataCache() async {
    final cached = _metadataCache;
    if (cached != null) return cached;
    try {
      if (await _metadataFile.exists()) {
        final decoded = jsonDecode(await _metadataFile.readAsString());
        if (decoded is Map) {
          return _metadataCache = Map<String, Object?>.from(decoded);
        }
      }
    } on FormatException {
      // A truncated cache is worth nothing but must never break the gallery;
      // it is simply rebuilt from scratch.
    } on FileSystemException {
      // Same for an unreadable one.
    }
    return _metadataCache = <String, Object?>{};
  }

  Future<void> _saveMetadataCache(Map<String, Object?> cache) async {
    try {
      await Directory(_supportDirectory).create(recursive: true);
      await _metadataFile.writeAsString(jsonEncode(cache));
    } on FileSystemException {
      // Losing the cache only costs a re-probe next time.
    }
  }

  /// Size and modification time are part of the key so an edited or replaced
  /// file never keeps the previous version's duration or thumbnail.
  static String _cacheKey(String path, FileStat stat) {
    return '$path|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
  }

  static String _fileName(String path) {
    final separator = path.lastIndexOf(RegExp(r'[\\/]'));
    return separator < 0 ? path : path.substring(separator + 1);
  }

  static String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  static int _even(double value) {
    final rounded = value.round();
    final even = rounded.isEven ? rounded : rounded + 1;
    return even < 2 ? 2 : even;
  }
}
