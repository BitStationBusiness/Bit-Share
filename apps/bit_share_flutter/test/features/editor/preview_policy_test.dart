import 'package:bit_share/features/editor/preview_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('optimizes codecs that decode slowly in Windows Media Foundation', () {
    expect(requiresOptimizedWindowsPreview('av1'), isTrue);
    expect(requiresOptimizedWindowsPreview('VP9'), isTrue);
    expect(requiresOptimizedWindowsPreview('vp8'), isTrue);
  });

  test('keeps native-friendly preview codecs untouched', () {
    expect(requiresOptimizedWindowsPreview('h264'), isFalse);
    expect(requiresOptimizedWindowsPreview('hevc'), isFalse);
    expect(requiresOptimizedWindowsPreview(null), isFalse);
  });
}
