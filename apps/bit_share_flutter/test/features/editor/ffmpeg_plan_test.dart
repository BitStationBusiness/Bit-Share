import 'package:bit_share/features/editor/edit_request.dart';
import 'package:bit_share/features/editor/ffmpeg_plan.dart';
import 'package:bit_share/features/gallery/media_item.dart';
import 'package:flutter_test/flutter_test.dart';

MediaItem _item(MediaKind kind) => MediaItem(
  id: 'source',
  uri: 'C:/Bit-Share/source.${kind == MediaKind.audio ? 'mp3' : 'mp4'}',
  name: 'source.${kind == MediaKind.audio ? 'mp3' : 'mp4'}',
  mimeType: kind == MediaKind.audio ? 'audio/mpeg' : 'video/mp4',
  kind: kind,
  sizeBytes: 1,
  width: kind == MediaKind.video ? 1920 : null,
  height: kind == MediaKind.video ? 1080 : null,
);

MediaEditRequest _request({
  required MediaKind kind,
  double volume = 1.0,
  double speed = 1.0,
  bool mute = false,
}) => MediaEditRequest(
  source: _item(kind),
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
