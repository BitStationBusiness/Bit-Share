import 'package:bit_share/features/update/update_dialog.dart';
import 'package:bit_share/features/update/update_release.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('muestra solo mejoras legibles de las notas de release', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(440, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: const UpdateDialog(
          release: UpdateRelease(
            version: '1.0.10',
            tag: 'v1.0.10',
            notes: '''# Bit-Share v1.0.10

## Mejoras

- Primera mejora visible.
- Segunda mejora visible.
- Tercera mejora visible.

## Archivos

- Bit-Share-Setup-1.0.10.exe
''',
            downloadUrl: 'https://example.com/Bit-Share-Setup-1.0.10.exe',
            assetSizeBytes: 10 * 1024 * 1024,
          ),
        ),
      ),
    );

    expect(find.text('Primera mejora visible.'), findsOneWidget);
    expect(find.text('Segunda mejora visible.'), findsOneWidget);
    expect(find.text('Tercera mejora visible.'), findsOneWidget);
    expect(find.textContaining('Bit-Share-Setup-1.0.10.exe'), findsNothing);
    expect(find.text('Más tarde'), findsOneWidget);
    expect(find.text('Actualizar ahora'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('update-dialog-card'))).width,
      lessThanOrEqualTo(320),
    );
    expect(tester.takeException(), isNull);
  });
}
