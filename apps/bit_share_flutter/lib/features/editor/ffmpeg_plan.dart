import 'package:flutter/foundation.dart';

import '../../core/media_formatting.dart';
import '../gallery/media_item.dart';
import 'edit_request.dart';

/// A ready-to-run ffmpeg invocation plus what the caller needs to know about
/// it. Building this is pure so the exact command every edit produces is
/// covered by unit tests instead of only being observable on a device.
@immutable
class FfmpegEditPlan {
  const FfmpegEditPlan({
    required this.arguments,
    required this.outputExtension,
    required this.streamCopy,
    required this.expectedDuration,
  });

  /// Arguments after the executable itself.
  final List<String> arguments;

  /// Extension the output file must carry for ffmpeg to pick the right muxer.
  final String outputExtension;

  /// True when the plan re-muxes without re-encoding, which finishes almost
  /// instantly and lets the UI skip the percentage entirely.
  final bool streamCopy;

  /// How long the result will be, i.e. the denominator for progress.
  final Duration expectedDuration;
}

/// Extension the export will be written with. Audio keeps MP3 as MP3 so an
/// edited track stays playable everywhere the original was; everything else
/// lands in an MP4/M4A container.
String editOutputExtension(MediaEditRequest request) {
  if (request.source.kind == MediaKind.audio) {
    return request.source.extension == 'mp3' ? 'mp3' : 'm4a';
  }
  return 'mp4';
}

/// Builds the ffmpeg command for [request].
///
/// Trimming always re-encodes. Stream copying would snap the cut to the
/// nearest keyframe, which can be seconds away from where the user placed the
/// handle — the edit would silently not be the one they asked for.
FfmpegEditPlan buildFfmpegEditPlan({
  required MediaEditRequest request,
  required String inputPath,
  required String outputPath,
}) {
  assert(request.hasChanges, 'Nothing to export: the request changes nothing.');
  final isVideo = request.source.kind == MediaKind.video;
  final arguments = <String>[
    '-hide_banner',
    '-nostdin',
    '-loglevel',
    'error',
    '-y',
    '-progress',
    'pipe:1',
    '-nostats',
  ];

  // Both seek and duration are input options so the filter chain is free to
  // change the output length. `-t` as an *output* option would instead clamp
  // the result and truncate anything slowed down below 1x.
  if (request.start > Duration.zero) {
    arguments.addAll(['-ss', formatFfmpegTimestamp(request.start)]);
  }
  if (request.end < request.sourceDuration) {
    arguments.addAll(['-t', formatFfmpegTimestamp(request.selectionDuration)]);
  }
  arguments.addAll(['-i', inputPath]);

  final keepsAudio = !(isVideo && request.mute);
  final streamCopy = isVideo && _canStreamCopy(request);

  if (isVideo) {
    arguments.addAll(['-map', '0:v:0']);
    if (keepsAudio) arguments.addAll(['-map', '0:a:0?']);

    final videoFilters = _videoFilters(request);
    if (streamCopy) {
      arguments.addAll(['-c:v', 'copy']);
    } else {
      if (videoFilters.isNotEmpty) {
        arguments.addAll(['-vf', videoFilters.join(',')]);
      }
      arguments.addAll([
        '-c:v',
        'libx264',
        '-preset',
        'veryfast',
        '-crf',
        '23',
        '-pix_fmt',
        'yuv420p',
      ]);
    }

    if (!keepsAudio) {
      arguments.add('-an');
    } else if (streamCopy) {
      arguments.addAll(['-c:a', 'copy']);
    } else {
      if (request.isSpeedAdjusted) {
        arguments.addAll(['-af', 'atempo=${_number(request.speed)}']);
      }
      arguments.addAll(['-c:a', 'aac', '-b:a', '160k']);
    }
    arguments.addAll(['-movflags', '+faststart']);
  } else {
    // Cover art rides along as a video stream; carrying it through a filtered
    // audio re-encode is what makes an edited M4A fail to mux.
    arguments.addAll(['-vn', '-map', '0:a:0']);
    if (request.isSpeedAdjusted) {
      arguments.addAll(['-af', 'atempo=${_number(request.speed)}']);
    }
    if (editOutputExtension(request) == 'mp3') {
      arguments.addAll(['-c:a', 'libmp3lame', '-q:a', '2']);
    } else {
      arguments.addAll(['-c:a', 'aac', '-b:a', '192k']);
    }
  }

  arguments.add(outputPath);

  return FfmpegEditPlan(
    arguments: List.unmodifiable(arguments),
    outputExtension: editOutputExtension(request),
    streamCopy: streamCopy,
    expectedDuration: request.outputDuration,
  );
}

/// Muting on its own touches no frames, so the video track can be copied
/// verbatim. Any other change needs a real encode.
bool _canStreamCopy(MediaEditRequest request) {
  return request.mute &&
      !request.isTrimmed &&
      !request.isRotated &&
      !request.isSpeedAdjusted &&
      !request.isRescaled;
}

/// Scale runs before transpose, so its target is the pre-rotation size;
/// setpts runs last so it is not disturbed by geometry changes.
List<String> _videoFilters(MediaEditRequest request) {
  final filters = <String>[];
  final scaled = request.scaledSize;
  if (scaled != null) {
    filters.add('scale=${scaled.width}:${scaled.height}');
  }
  switch (request.rotation) {
    case EditorRotation.none:
      break;
    case EditorRotation.clockwise:
      filters.add('transpose=1');
    case EditorRotation.counterClockwise:
      filters.add('transpose=2');
    case EditorRotation.half:
      filters.addAll(['transpose=1', 'transpose=1']);
  }
  if (request.isSpeedAdjusted) {
    filters.add('setpts=PTS/${_number(request.speed)}');
  }
  return filters;
}

/// `2.0.toString()` is `"2.0"`, which ffmpeg accepts, but `1.25` must not be
/// rounded away — trailing zeros are trimmed and the rest is left intact.
String _number(double value) {
  final text = value.toStringAsFixed(3);
  return text.replaceFirst(RegExp(r'\.?0+$'), '');
}
