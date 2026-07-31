import 'dart:async';

import 'package:flutter/material.dart';

import 'update_checker.dart';
import 'update_dialog.dart';
import 'update_release.dart';

/// Wraps the app's home widget and, a few seconds after first paint, asks
/// GitHub once for a newer release. "Later" is intentionally not persisted:
/// closing the card just means the next launch asks again, same as
/// BitMusic's updater.
class UpdateGate extends StatefulWidget {
  const UpdateGate({required this.child, super.key});

  final Widget child;

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> {
  static const _checker = UpdateChecker();

  /// Late enough that first paint and any startup work own the CPU, early
  /// enough that it still reads as "it told me when I opened it".
  static const _bootDelay = Duration(seconds: 3);

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_bootDelay, _check);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    final UpdateRelease? release;
    try {
      release = await _checker.checkForUpdate();
    } on Object {
      return;
    }
    if (release == null || !mounted) return;
    final navigatorState = Navigator.of(context, rootNavigator: true);
    await showDialog<void>(
      context: navigatorState.context,
      builder: (_) => UpdateDialog(release: release!),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
