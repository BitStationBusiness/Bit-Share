import 'package:flutter/foundation.dart';

/// What a gallery entry is, which decides how it is presented (video frame vs.
/// cover art) and which edit controls apply to it.
enum MediaKind {
  video,
  audio,
  image;

  /// Resolves the kind from the MIME type, falling back to the file extension
  /// because Android reports `application/octet-stream` for files whose
  /// extension it does not recognise and Windows has no MIME type at all.
  static MediaKind resolve({required String mimeType, required String name}) {
    final normalized = mimeType.toLowerCase();
    if (normalized.startsWith('video/')) return MediaKind.video;
    if (normalized.startsWith('audio/')) return MediaKind.audio;
    if (normalized.startsWith('image/')) return MediaKind.image;
    return kindForExtension(name);
  }

  static MediaKind kindForExtension(String name) {
    final dot = name.lastIndexOf('.');
    final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    if (videoExtensions.contains(extension)) return MediaKind.video;
    if (audioExtensions.contains(extension)) return MediaKind.audio;
    return MediaKind.image;
  }

  static const videoExtensions = <String>{
    'mp4',
    'm4v',
    'mkv',
    'webm',
    'mov',
    'avi',
    '3gp',
    'ts',
  };

  static const audioExtensions = <String>{
    'm4a',
    'mp3',
    'aac',
    'opus',
    'ogg',
    'oga',
    'wav',
    'flac',
  };

  static const imageExtensions = <String>{
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'bmp',
  };
}

/// One file Bit-Share downloaded, as the gallery sees it.
@immutable
class MediaItem {
  const MediaItem({
    required this.id,
    required this.name,
    required this.uri,
    required this.kind,
    required this.mimeType,
    required this.sizeBytes,
    this.path,
    this.duration,
    this.modifiedAt,
    this.width,
    this.height,
  });

  factory MediaItem.fromMap(Map<Object?, Object?> map) {
    final name = map['name'] as String? ?? '';
    final mimeType = map['mimeType'] as String? ?? '';
    final durationMs = (map['durationMs'] as num?)?.toInt();
    final modifiedMs = (map['modifiedAtMs'] as num?)?.toInt();
    return MediaItem(
      id: map['id'] as String? ?? '',
      name: name,
      uri: map['uri'] as String? ?? '',
      path: map['path'] as String?,
      kind: MediaKind.resolve(mimeType: mimeType, name: name),
      mimeType: mimeType,
      sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
      duration: durationMs == null || durationMs <= 0
          ? null
          : Duration(milliseconds: durationMs),
      modifiedAt: modifiedMs == null || modifiedMs <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(modifiedMs),
      width: (map['width'] as num?)?.toInt(),
      height: (map['height'] as num?)?.toInt(),
    );
  }

  /// Stable identity used for selection, cache keys and delete calls. On
  /// Android this is the MediaStore content URI, on Windows the absolute path.
  final String id;

  final String name;

  /// What the player opens: a `content://` URI on Android, an absolute file
  /// path on Windows.
  final String uri;

  /// Absolute filesystem path when the platform exposes one. Android only
  /// exposes it for files the app itself can still reach directly, so it is
  /// nullable and must never be assumed present.
  final String? path;

  final MediaKind kind;
  final String mimeType;
  final int sizeBytes;
  final Duration? duration;
  final DateTime? modifiedAt;
  final int? width;
  final int? height;

  /// Name without the extension, for titles and for naming an edited copy.
  String get baseName {
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  String get extension {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  /// Whether the editor has anything to offer for this entry. Images are
  /// listed and viewable but Bit-Share does not ship an image editor.
  bool get isEditable => kind != MediaKind.image;

  @override
  bool operator ==(Object other) => other is MediaItem && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
