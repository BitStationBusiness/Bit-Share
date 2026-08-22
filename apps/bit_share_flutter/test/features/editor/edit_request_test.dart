import 'package:bit_share/features/editor/edit_request.dart';
import 'package:bit_share/features/gallery/media_item.dart';
import 'package:flutter_test/flutter_test.dart';

MediaItem _video() => const MediaItem(
  id: 'source',
  uri: 'C:/Bit-Share/source.mp4',
  name: 'source.mp4',
  mimeType: 'video/mp4',
  kind: MediaKind.video,
  sizeBytes: 1,
  width: 1920,
  height: 1080,
);

MediaEditRequest _request({required Duration start, required Duration end}) {
  return MediaEditRequest(
    source: _video(),
    sourceDuration: const Duration(seconds: 20),
    start: start,
    end: end,
  );
}

void main() {
  test('una selección de longitud cero no es exportable', () {
    final request = _request(
      start: const Duration(seconds: 8),
      end: const Duration(seconds: 8),
    );

    // The handles counting as "changed" is what used to let this reach
    // ffmpeg, which turned it into `-t 0` and wrote an empty file.
    expect(request.hasChanges, isTrue);
    expect(request.hasUsableSelection, isFalse);
    expect(request.isExportable, isFalse);
  });

  test('una selección por debajo del mínimo no es exportable', () {
    final request = _request(
      start: const Duration(seconds: 8),
      end: const Duration(seconds: 8, milliseconds: 199),
    );

    expect(request.isExportable, isFalse);
  });

  test('una selección justo en el mínimo sí es exportable', () {
    final request = _request(
      start: const Duration(seconds: 8),
      end: const Duration(seconds: 8) + editorMinimumSelection,
    );

    expect(request.selectionDuration, editorMinimumSelection);
    expect(request.isExportable, isTrue);
  });

  test('un clip intacto no es exportable aunque dure lo suficiente', () {
    final request = _request(
      start: Duration.zero,
      end: const Duration(seconds: 20),
    );

    expect(request.hasUsableSelection, isTrue);
    expect(request.hasChanges, isFalse);
    expect(request.isExportable, isFalse);
  });

  test('el resumen del resultado refleja el recorte y la velocidad', () {
    final request = _request(
      start: const Duration(seconds: 4),
      end: const Duration(seconds: 14),
    ).copyWith(speed: 2.0, quality: EditorQuality.high);

    expect(request.selectionDuration, const Duration(seconds: 10));
    expect(request.outputDuration, const Duration(seconds: 5));
    expect(request.outputSize, (width: 1280, height: 720));
  });

  test('la rotación intercambia los ejes del tamaño de salida', () {
    final request = _request(
      start: Duration.zero,
      end: const Duration(seconds: 20),
    ).copyWith(rotation: EditorRotation.clockwise, quality: EditorQuality.high);

    expect(request.outputSize, (width: 720, height: 1280));
  });
}
