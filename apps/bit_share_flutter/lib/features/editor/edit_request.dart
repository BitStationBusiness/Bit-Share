import 'package:flutter/foundation.dart';

import '../gallery/media_item.dart';

/// Quarter turns the editor can apply, in the direction the preview shows.
enum EditorRotation {
  none(0, 'Sin girar'),
  clockwise(90, '90° derecha'),
  half(180, '180°'),
  counterClockwise(270, '90° izquierda');

  const EditorRotation(this.degrees, this.label);

  final int degrees;
  final String label;

  EditorRotation get next => switch (this) {
    EditorRotation.none => EditorRotation.clockwise,
    EditorRotation.clockwise => EditorRotation.half,
    EditorRotation.half => EditorRotation.counterClockwise,
    EditorRotation.counterClockwise => EditorRotation.none,
  };

  /// Whether the frame's width and height swap places once applied.
  bool get swapsAxes =>
      this == EditorRotation.clockwise ||
      this == EditorRotation.counterClockwise;
}

/// Output size tiers, expressed as the longest side the result may have so a
/// portrait clip keeps the same intuitive meaning as a landscape one.
enum EditorQuality {
  original(null, 'Original'),
  high(1280, '720p'),
  medium(854, '480p'),
  low(640, '360p');

  const EditorQuality(this.longestSide, this.label);

  final int? longestSide;
  final String label;
}

/// Playback rates offered by the editor. Bounded to the range a single
/// ffmpeg `atempo` handles without chaining, which keeps audio artefact-free.
const editorSpeeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// An edit the user has composed but not yet exported.
@immutable
class MediaEditRequest {
  const MediaEditRequest({
    required this.source,
    required this.sourceDuration,
    required this.start,
    required this.end,
    this.mute = false,
    this.volume = 1.0,
    this.rotation = EditorRotation.none,
    this.speed = 1.0,
    this.quality = EditorQuality.original,
  });

  /// A request that changes nothing, i.e. the state the editor opens in.
  factory MediaEditRequest.untouched({
    required MediaItem source,
    required Duration duration,
  }) {
    return MediaEditRequest(
      source: source,
      sourceDuration: duration,
      start: Duration.zero,
      end: duration,
    );
  }

  final MediaItem source;

  /// Full length of the source, which is what [end] is compared against to
  /// decide whether the clip was actually trimmed.
  final Duration sourceDuration;

  final Duration start;
  final Duration end;
  final bool mute;

  /// Gain applied to the audio track. `1.0` preserves the original level,
  /// `0.0` produces silence, and values up to `2.0` allow a quiet clip to be
  /// boosted without exposing an unbounded (and unsafe) FFmpeg expression.
  final double volume;
  final EditorRotation rotation;
  final double speed;
  final EditorQuality quality;

  MediaEditRequest copyWith({
    Duration? start,
    Duration? end,
    bool? mute,
    double? volume,
    EditorRotation? rotation,
    double? speed,
    EditorQuality? quality,
  }) {
    return MediaEditRequest(
      source: source,
      sourceDuration: sourceDuration,
      start: start ?? this.start,
      end: end ?? this.end,
      mute: mute ?? this.mute,
      volume: (volume ?? this.volume).clamp(0.0, 2.0).toDouble(),
      rotation: rotation ?? this.rotation,
      speed: speed ?? this.speed,
      quality: quality ?? this.quality,
    );
  }

  /// Length of the selected span before the speed change.
  Duration get selectionDuration {
    final span = end - start;
    return span.isNegative ? Duration.zero : span;
  }

  /// Length of the exported file, i.e. the selection after the speed change.
  Duration get outputDuration {
    if (speed == 1.0) return selectionDuration;
    return Duration(
      microseconds: (selectionDuration.inMicroseconds / speed).round(),
    );
  }

  /// True once either handle has moved. Compared with a tolerance because the
  /// trim slider works in milliseconds while durations are probed in
  /// microseconds, so an untouched handle rarely lands on an exact match.
  bool get isTrimmed {
    const tolerance = Duration(milliseconds: 40);
    return start > tolerance || (sourceDuration - end) > tolerance;
  }

  bool get isRotated => rotation != EditorRotation.none;

  bool get isSpeedAdjusted => speed != 1.0;

  bool get isVolumeAdjusted => volume != 1.0;

  /// Downscaling only ever shrinks: asking for 720p on a 480p source would
  /// otherwise upscale it, inflating the file for no visible gain.
  bool get isRescaled => scaledSize != null;

  /// Whether exporting would produce anything different from the source.
  /// The save action stays disabled until this is true.
  bool get hasChanges =>
      isTrimmed ||
      mute ||
      isVolumeAdjusted ||
      isRotated ||
      isSpeedAdjusted ||
      isRescaled;

  /// Audio files have no frame to rotate or rescale, and muting one would
  /// just produce silence — the editor hides those controls for them.
  bool get supportsVideoControls => source.kind == MediaKind.video;

  /// Both audio and video may carry sound. Images never reach the editor.
  bool get supportsAudioControls => source.kind != MediaKind.image;

  /// Frame size after downscaling but *before* rotation — the size the
  /// `scale` filter is given, since it runs ahead of `transpose` in the chain.
  /// Null when the source size is unknown or no downscale applies.
  ({int width, int height})? get scaledSize {
    final width = source.width;
    final height = source.height;
    final target = quality.longestSide;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    if (target == null) return null;
    final longest = width > height ? width : height;
    if (longest <= target) return null;
    final factor = target / longest;
    return (
      width: _evenDimension(width * factor),
      height: _evenDimension(height * factor),
    );
  }

  /// Exact pixel size of the result, or null when the source size is unknown.
  /// Computed here rather than left to an ffmpeg expression so the value can
  /// be shown in the UI and asserted in tests.
  ({int width, int height})? get outputSize {
    final width = source.width;
    final height = source.height;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    final scaled = scaledSize ?? (width: width, height: height);
    return rotation.swapsAxes
        ? (width: scaled.height, height: scaled.width)
        : scaled;
  }
}

/// H.264 requires even dimensions, and a zero-size axis is never valid, so
/// every computed dimension is rounded to the nearest even number ≥ 2.
int _evenDimension(double value) {
  final rounded = value.round();
  final even = rounded.isEven ? rounded : rounded + 1;
  return even < 2 ? 2 : even;
}
