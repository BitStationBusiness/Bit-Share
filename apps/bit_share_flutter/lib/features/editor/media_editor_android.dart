import 'dart:async';

import 'package:flutter/services.dart';

import '../gallery/media_item.dart';
import '../gallery/media_library_android.dart';
import 'media_editor.dart';

/// Progress for the running export. Kotlin owns the ffmpeg process, so the
/// percentage arrives out-of-band on this stream rather than as part of the
/// export call's own result.
const galleryEventChannel = EventChannel('bitshare/gallery/events');

class AndroidMediaEditor implements MediaEditor {
  AndroidMediaEditor({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? galleryMethodChannel,
      _events = events ?? galleryEventChannel;

  final MethodChannel _methods;
  final EventChannel _events;

  @override
  Future<MediaItem> probe(MediaItem item) async {
    try {
      final response = await _methods.invokeMapMethod<Object?, Object?>(
        'probe',
        {'id': item.id},
      );
      if (response == null) return item;
      return MediaItem.fromMap(response);
    } on PlatformException catch (error) {
      throw MediaEditException(
        error.message ?? 'No se pudo leer la información del archivo.',
      );
    }
  }

  @override
  Future<MediaItem> export(
    MediaEditRequest request, {
    required void Function(double progress) onProgress,
  }) async {
    final subscription = _events.receiveBroadcastStream().listen((raw) {
      if (raw is! Map) return;
      if (raw['type'] != 'editProgress') return;
      final progress = (raw['progress'] as num?)?.toDouble();
      if (progress != null) onProgress(progress.clamp(0, 1));
    }, onError: (Object _) {});
    try {
      final response = await _methods.invokeMapMethod<Object?, Object?>(
        'export',
        {
          'id': request.source.id,
          'startMs': request.start.inMilliseconds,
          'endMs': request.end.inMilliseconds,
          'sourceDurationMs': request.sourceDuration.inMilliseconds,
          'mute': request.mute,
          'rotationDegrees': request.rotation.degrees,
          'speed': request.speed,
          'longestSide': request.quality.longestSide,
        },
      );
      if (response == null) {
        throw const MediaEditException('El editor no devolvió un archivo.');
      }
      return MediaItem.fromMap(response);
    } on PlatformException catch (error) {
      if (error.code == 'edit_cancelled') throw const MediaEditCancelled();
      throw MediaEditException(
        error.message ?? 'No se pudo guardar el archivo editado.',
      );
    } finally {
      unawaited(subscription.cancel());
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _methods.invokeMethod<void>('cancelExport');
    } on PlatformException {
      // The export had already finished or failed; nothing left to stop.
    }
  }
}
