import 'package:bit_share/app/bit_share_app.dart';
import 'package:bit_share/features/share_receiver/share_receiver_screen.dart';
import 'package:bit_share/features/update/update_gate.dart';
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

  testWidgets(
    'el receptor de enlaces compartidos también pasa por el chequeo de '
    'actualización',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await tester.pumpWidget(const BitShareApp(openedFromShare: true));

        expect(
          find.ancestor(
            of: find.byType(ShareReceiverScreen),
            matching: find.byType(UpdateGate),
          ),
          findsOneWidget,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
