import 'package:bit_share/features/update/update_checker.dart';
import 'package:bit_share/features/update/update_gate.dart';
import 'package:bit_share/features/update/update_release.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Hands back a prepared answer per call, so a test can describe a flaky
/// network ("fails, fails, then works") without one.
class _ScriptedChecker extends UpdateChecker {
  _ScriptedChecker(this.answers);

  final List<UpdateCheckResult> answers;
  int calls = 0;

  @override
  Future<UpdateCheckResult> checkForUpdate() async {
    final answer = answers[calls < answers.length ? calls : answers.length - 1];
    calls++;
    return answer;
  }
}

const _release = UpdateRelease(
  version: '9.9.9',
  tag: 'v9.9.9',
  notes: '# Bit-Share 9.9.9\n\n- Una mejora legible.\n',
  downloadUrl: 'https://example.invalid/Bit-Share-v9.9.9.apk',
  assetSizeBytes: 83 * 1024 * 1024,
);

Future<void> _pumpGate(WidgetTester tester, _ScriptedChecker checker) {
  return tester.pumpWidget(
    MaterialApp(
      home: UpdateGate(
        checker: checker,
        child: const Scaffold(body: Text('inicio')),
      ),
    ),
  );
}

void main() {
  testWidgets('un chequeo fallido se reintenta hasta que responde', (
    tester,
  ) async {
    final checker = _ScriptedChecker([
      const UpdateCheckResult.failed(),
      const UpdateCheckResult.failed(),
      const UpdateCheckResult(UpdateCheckStatus.updateAvailable, _release),
    ]);
    await _pumpGate(tester, checker);

    // A cold start on mobile data commonly has no connectivity at the first
    // attempt; giving up there is what made the app look like it never
    // announced updates.
    await tester.pump(const Duration(seconds: 4));
    expect(checker.calls, 1);
    expect(find.text('Actualización disponible'), findsNothing);

    await tester.pump(const Duration(seconds: 13));
    expect(checker.calls, 2);

    await tester.pump(const Duration(seconds: 41));
    await tester.pump();
    expect(checker.calls, 3);
    expect(find.text('Actualización disponible'), findsOneWidget);
  });

  testWidgets('estar al día no genera reintentos', (tester) async {
    final checker = _ScriptedChecker([const UpdateCheckResult.upToDate()]);
    await _pumpGate(tester, checker);

    await tester.pump(const Duration(seconds: 4));
    expect(checker.calls, 1);

    // Nothing about "already current" can change while the app is open, so
    // coming back to ask again would only waste GitHub's rate limit.
    await tester.pump(const Duration(minutes: 10));
    expect(checker.calls, 1);
  });

  testWidgets('los reintentos se agotan en lugar de repetirse sin fin', (
    tester,
  ) async {
    final checker = _ScriptedChecker([const UpdateCheckResult.failed()]);
    await _pumpGate(tester, checker);

    // Walks the whole schedule: 3s + 12s + 40s + 3min.
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 13));
    await tester.pump(const Duration(seconds: 41));
    await tester.pump(const Duration(minutes: 4));
    expect(checker.calls, 4);

    // A pending timer here would fail the test on its own, which is the point:
    // the schedule has to end.
    await tester.pump(const Duration(minutes: 10));
    expect(checker.calls, 4);
  });

  testWidgets('una versión sin instalador no se reintenta', (tester) async {
    // A published tag whose assets do not include one for this platform is
    // reported as up to date: there is nothing to install and retrying will
    // never produce it.
    final checker = _ScriptedChecker([const UpdateCheckResult.upToDate()]);
    await _pumpGate(tester, checker);

    await tester.pump(const Duration(minutes: 5));
    expect(checker.calls, 1);
    expect(find.text('Actualización disponible'), findsNothing);
  });
}
