import 'package:bit_share/features/editor/editor_screen.dart';
import 'package:bit_share/features/editor/media_editor.dart';
import 'package:bit_share/features/gallery/media_library.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Returns the item unchanged, so the editor gets a duration without any
/// platform channel. The preview still fails to initialise here — there is no
/// video plugin under `flutter test` — which is exactly the state this suite
/// needs: it is the same state a phone reaches when the codec cannot be
/// previewed, and the trim controls must survive it.
class _FakeEditor implements MediaEditor {
  @override
  Future<MediaItem> probe(MediaItem item) async => item;

  @override
  Future<MediaItem> export(
    MediaEditRequest request, {
    required void Function(double progress) onProgress,
  }) async => request.source;

  @override
  Future<void> cancel() async {}
}

class _FakeLibrary implements MediaLibrary {
  // The editor only takes a library to hand back to the gallery; it never
  // calls into it.
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _portraitClip = MediaItem(
  id: 'clip',
  uri: '/storage/emulated/0/Download/Bit-Share/clip.mp4',
  name: 'Un_nombre_de_archivo_bastante_largo_como_los_reales [abc123].mp4',
  mimeType: 'video/mp4',
  kind: MediaKind.video,
  sizeBytes: 22 * 1024 * 1024,
  width: 608,
  height: 1080,
  duration: Duration(minutes: 12, seconds: 34),
);

Future<void> _pumpEditor(WidgetTester tester, Size physicalSize) async {
  tester.view.physicalSize = physicalSize;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: EditorScreen(
        item: _portraitClip,
        library: _FakeLibrary(),
        editor: _FakeEditor(),
      ),
    ),
  );
  // Not pumpAndSettle: the preview attempt never resolves cleanly under test.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Runs [body] as an Android test. The platform override has to be undone
/// before the test body returns: the binding checks that foundation debug
/// variables are clean at that point, which is earlier than tearDown.
void testPhone(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  // 1080x2412 @ 3.0 is a real phone: 360x804dp, narrower than the tablet the
  // layout was originally checked on. A RenderFlex overflow anywhere in here
  // fails the test on its own.
  testPhone('el editor cabe en un móvil vertical de 360dp', (tester) async {
    await _pumpEditor(tester, const Size(1080, 2412));

    expect(find.text('Editar clip'), findsOneWidget);
    expect(find.text('RECORTE'), findsOneWidget);
    expect(find.text('AJUSTES'), findsOneWidget);
  });

  testPhone('el recorte sigue disponible sin vista previa', (tester) async {
    await _pumpEditor(tester, const Size(1080, 2412));

    // The whole point of decoupling the two: an unpreviewable clip can still
    // be cut. Both edge readouts and the duration must be on screen.
    expect(find.text('Inicio'), findsOneWidget);
    expect(find.text('Fin'), findsOneWidget);
    expect(find.text('12:34'), findsWidgets);
  });

  testPhone('no ofrece atajos de teclado en un móvil', (tester) async {
    await _pumpEditor(tester, const Size(1080, 2412));

    expect(find.text('Guardar copia'), findsOneWidget);
    expect(find.textContaining('Ctrl+S'), findsNothing);
  });

  testPhone('un clip intacto no se puede guardar todavía', (tester) async {
    await _pumpEditor(tester, const Size(1080, 2412));

    expect(
      find.textContaining('Sin cambios todavía'),
      findsOneWidget,
      reason: 'el resumen debe explicar por qué Guardar está deshabilitado',
    );
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Guardar copia'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
  });

  testPhone('también cabe en un móvil pequeño de 320dp', (tester) async {
    // The narrowest width Android still ships; if the trim row survives here
    // it survives anywhere.
    await _pumpEditor(tester, const Size(960, 2100));

    expect(find.text('RECORTE'), findsOneWidget);
    expect(find.text('Inicio'), findsOneWidget);
  });
}
