import 'package:bit_share/features/editor/edit_request.dart';
import 'package:bit_share/features/editor/ffmpeg_plan.dart';
import 'package:bit_share/features/gallery/media_item.dart';
import 'package:flutter_test/flutter_test.dart';

MediaItem _item(MediaKind kind, {String? extension}) {
  final suffix =
      extension ?? (kind == MediaKind.audio ? 'mp3' : 'mp4');
  return MediaItem(
    id: 'source',
    uri: 'C:/Bit-Share/source.$suffix',
    name: 'source.$suffix',
    mimeType: kind == MediaKind.audio ? 'audio/mpeg' : 'video/mp4',
    kind: kind,
    sizeBytes: 1,
    width: kind == MediaKind.video ? 1920 : null,
    height: kind == MediaKind.video ? 1080 : null,
  );
}

MediaEditRequest _request({
  required MediaKind kind,
  double volume = 1.0,
  double speed = 1.0,
  bool mute = false,
  String? extension,
}) => MediaEditRequest(
  source: _item(kind, extension: extension),
  sourceDuration: const Duration(seconds: 20),
  start: Duration.zero,
  end: const Duration(seconds: 20),
  volume: volume,
  speed: speed,
  mute: mute,
);

void main() {
  group('EditorRotation', () {
    test('uses the same direction in the preview and final render', () {
      expect(EditorRotation.none.previewQuarterTurns, 0);
      expect(EditorRotation.clockwise.previewQuarterTurns, 1);
      expect(EditorRotation.half.previewQuarterTurns, 2);
      expect(EditorRotation.counterClockwise.previewQuarterTurns, 3);
    });
  });

  group('buildFfmpegEditPlan', () {
    test('applies gain to an audio export', () {
      final plan = buildFfmpegEditPlan(
        request: _request(kind: MediaKind.audio, volume: 1.5),
        inputPath: 'input.mp3',
        outputPath: 'output.mp3',
      );

      expect(plan.arguments, containsAllInOrder(['-af', 'volume=1.5']));
      expect(plan.arguments, containsAllInOrder(['-c:a', 'libmp3lame']));
    });

    test('combines speed and volume in one audio filter chain', () {
      final plan = buildFfmpegEditPlan(
        request: _request(kind: MediaKind.video, speed: 1.25, volume: 0.5),
        inputPath: 'input.mp4',
        outputPath: 'output.mp4',
      );

      expect(
        plan.arguments,
        containsAllInOrder(['-af', 'atempo=1.25,volume=0.5']),
      );
      expect(plan.streamCopy, isFalse);
    });

    test('exports every audio source as MP3, whatever it arrived as', () {
      for (final source in ['mp3', 'm4a', 'opus', 'webm']) {
        final request = _request(
          kind: MediaKind.audio,
          extension: source,
          volume: 1.5,
        );

        expect(editOutputExtension(request), 'mp3', reason: source);
        expect(
          buildFfmpegEditPlan(
            request: request,
            inputPath: 'input.$source',
            outputPath: 'output.mp3',
          ).arguments,
          containsAllInOrder(['-c:a', 'libmp3lame']),
          reason: source,
        );
      }
    });

    test('exports every video source as MP4', () {
      for (final source in ['mp4', 'webm', 'mkv']) {
        expect(
          editOutputExtension(
            _request(kind: MediaKind.video, extension: source, mute: true),
          ),
          'mp4',
          reason: source,
        );
      }
    });

    test('stream-copies a muted MP4 but re-encodes a muted WebM', () {
      // VP9/AV1 out of a .webm has no MP4 tag: `-c:v copy` would fail the
      // export outright rather than produce a silent clip.
      expect(
        buildFfmpegEditPlan(
          request: _request(kind: MediaKind.video, mute: true),
          inputPath: 'input.mp4',
          outputPath: 'output.mp4',
        ).streamCopy,
        isTrue,
      );

      final webm = buildFfmpegEditPlan(
        request: _request(
          kind: MediaKind.video,
          mute: true,
          extension: 'webm',
        ),
        inputPath: 'input.webm',
        outputPath: 'output.mp4',
      );
      expect(webm.streamCopy, isFalse);
      expect(webm.arguments, containsAllInOrder(['-c:v', 'libx264']));
    });

    test('does not stream-copy when the volume changes', () {
      final plan = buildFfmpegEditPlan(
        request: _request(kind: MediaKind.video, mute: true, volume: 0.5),
        inputPath: 'input.mp4',
        outputPath: 'output.mp4',
      );

      expect(plan.streamCopy, isFalse);
      expect(plan.arguments, containsAllInOrder(['-c:v', 'libx264', '-an']));
    });
  });
}
