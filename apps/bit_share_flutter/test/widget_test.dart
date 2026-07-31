import 'package:bit_share/app/bit_share_app.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('la pantalla principal presenta el receptor Android', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(const BitShareApp(openedFromShare: false));

      expect(find.text('BIT-SHARE'), findsOneWidget);
      expect(find.text('Listo para recibir'), findsOneWidget);
      expect(find.text('Receptor Android y contratos base'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
