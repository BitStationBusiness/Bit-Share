import 'dart:async';

import 'package:flutter/material.dart';

import 'update_checker.dart';
import 'update_dialog.dart';
import 'update_release.dart';

/// Wraps the app's home widget and asks GitHub for a newer release shortly
/// after first paint. "Later" is intentionally not persisted: closing the
/// card just means the next launch asks again, same as BitMusic's updater.
class UpdateGate extends StatefulWidget {
  const UpdateGate({required this.child, UpdateChecker? checker, super.key})
    : _checker = checker;

  final Widget child;

  /// Injectable so a test can drive the retry schedule without a network.
  final UpdateChecker? _checker;

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> {
  late final UpdateChecker _checker = widget._checker ?? const UpdateChecker();

  /// One attempt was never enough. A phone that has just been unlocked is
  /// routinely still bringing up mobile data three seconds in, and GitHub
  /// answers 403 once an address has spent its hourly allowance — either way
  /// the old code gave up in silence until the next cold start, which reads
  /// exactly like "the app never tells me there is an update".
  ///
  /// The first entry keeps the original timing: late enough that first paint
  /// owns the CPU, early enough to still feel like it told you on opening.
  static const _attemptDelays = <Duration>[
    Duration(seconds: 3),
    Duration(seconds: 12),
    Duration(seconds: 40),
    Duration(minutes: 3),
  ];

  Timer? _timer;
  int _attempt = 0;
  bool _dialogVisible = false;

  @override
  void initState() {
    super.initState();
    _scheduleNextAttempt();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _scheduleNextAttempt() {
    if (_attempt >= _attemptDelays.length) return;
    _timer = Timer(_attemptDelays[_attempt], _check);
    _attempt++;
  }

  Future<void> _check() async {
    if (!mounted || _dialogVisible) return;
    final result = await _checker.checkForUpdate();
    if (!mounted) return;
    final release = result.release;
    if (release == null) {
      // Only a failure is worth coming back for. Being up to date, or being
      // a build with no installer, will not change while the app is open.
      if (result.isRetryable) _scheduleNextAttempt();
      return;
    }
    _dialogVisible = true;
    try {
      await showUpdateDialog(context, release);
    } finally {
      _dialogVisible = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Shows the update card over whatever is on screen.
Future<void> showUpdateDialog(
  BuildContext context,
  UpdateRelease release,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  await showDialog<void>(
    context: navigator.context,
    builder: (_) => UpdateDialog(release: release),
  );
}

/// The check behind a "look for updates" control, as opposed to the silent
/// one on launch. A check the user asked for must answer even when the answer
/// is boring or bad — staying quiet here is what leaves someone convinced the
/// app simply never offers updates.
Future<void> checkForUpdatesInteractively(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    const SnackBar(
      duration: Duration(seconds: 20),
      content: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 12),
          Text('Buscando actualizaciones…'),
        ],
      ),
    ),
  );

  const checker = UpdateChecker();
  final result = await checker.checkForUpdate();
  if (!context.mounted) return;
  messenger.hideCurrentSnackBar();

  final release = result.release;
  if (release != null) {
    await showUpdateDialog(context, release);
    return;
  }
  messenger.showSnackBar(
    SnackBar(
      content: Text(switch (result.status) {
        UpdateCheckStatus.upToDate => 'Ya tienes la última versión.',
        UpdateCheckStatus.failed =>
          'No se pudo consultar si hay actualizaciones. '
              'Revisa la conexión e inténtalo de nuevo.',
        UpdateCheckStatus.unsupported =>
          'Esta copia no se actualiza automáticamente.',
        UpdateCheckStatus.updateAvailable => '',
      }),
    ),
  );
}
