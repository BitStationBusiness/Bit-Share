import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'update_installer.dart';
import 'update_release.dart';

enum _Stage { available, downloading, installing, error, done }

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({required this.release, super.key});

  final UpdateRelease release;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  static const _installer = UpdateInstaller();

  _Stage _stage = _Stage.available;
  int _received = 0;
  int _total = 0;
  String? _error;

  bool get _dismissible => _stage == _Stage.available || _stage == _Stage.error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: _dismissible,
      child: AlertDialog(
        icon: Icon(
          _stage == _Stage.error
              ? Icons.error_outline
              : Icons.rocket_launch_rounded,
          color: _stage == _Stage.error
              ? theme.colorScheme.error
              : theme.colorScheme.primary,
        ),
        title: Text(_title()),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: _buildBody(theme),
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: _buildActions(context),
      ),
    );
  }

  String _title() {
    switch (_stage) {
      case _Stage.installing:
        return 'Instalando actualización';
      case _Stage.error:
        return 'La actualización falló';
      default:
        return 'Actualización disponible';
    }
  }

  Widget _buildBody(ThemeData theme) {
    final mutedStyle = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    switch (_stage) {
      case _Stage.available:
        final notes = _notesLines(widget.release.notes);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Bit-Share ${widget.release.version} ya está disponible'
              '${widget.release.assetSizeBytes > 0 ? ' · ${_formatBytes(widget.release.assetSizeBytes)}' : ''}.',
            ),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              ...notes.map(
                (line) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('•  $line', style: mutedStyle),
                ),
              ),
            ],
          ],
        );
      case _Stage.downloading:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Descargando Bit-Share ${widget.release.version}…'),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: _total > 0 ? _received / _total : null,
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _total > 0
                  ? '${_formatBytes(_received)} / ${_formatBytes(_total)}'
                  : _formatBytes(_received),
              style: mutedStyle,
            ),
          ],
        );
      case _Stage.installing:
        return Text(
          Platform.isWindows
              ? 'Windows pedirá permiso y Bit-Share se reiniciará solo. '
                    'Puede tardar un minuto.'
              : 'Se abrió el instalador de Android. Sigue las indicaciones '
                    'en pantalla.',
          style: mutedStyle,
        );
      case _Stage.error:
        return Text(_error ?? 'No se pudo completar la actualización.');
      case _Stage.done:
        return const SizedBox.shrink();
    }
  }

  List<Widget> _buildActions(BuildContext context) {
    switch (_stage) {
      case _Stage.available:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Más tarde'),
          ),
          FilledButton(
            onPressed: _download,
            child: const Text('Actualizar ahora'),
          ),
        ];
      case _Stage.error:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cerrar'),
          ),
          FilledButton(onPressed: _download, child: const Text('Reintentar')),
        ];
      case _Stage.downloading:
        return const [];
      case _Stage.installing:
      case _Stage.done:
        return Platform.isAndroid
            ? [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cerrar'),
                ),
              ]
            : const [];
    }
  }

  Future<void> _download() async {
    setState(() {
      _stage = _Stage.downloading;
      _received = 0;
      _total = widget.release.assetSizeBytes;
      _error = null;
    });
    try {
      final file = await _installer.download(
        widget.release,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() => _stage = _Stage.installing);
      await _installer.apply(file);
      if (!mounted) return;
      if (Platform.isAndroid) {
        setState(() => _stage = _Stage.done);
      }
      // Windows: the installer takes over and Bit-Share is about to be
      // closed by the Restart Manager during the silent install, so there
      // is nothing further to do here.
    } on UpdateException catch (error) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _error = error.message;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _error = 'No se pudo completar la actualización.';
      });
    }
  }

  List<String> _notesLines(String notes) {
    return notes
        .split(RegExp(r'\r?\n'))
        .map((line) => line.replaceFirst(RegExp(r'^\s*[-*]\s+'), '').trim())
        .where(
          (line) =>
              line.isNotEmpty &&
              !RegExp(r'[0-9a-fA-F]{64}').hasMatch(line) &&
              !RegExp(r'^sha-?256', caseSensitive: false).hasMatch(line),
        )
        .take(6)
        .toList(growable: false);
  }

  String _formatBytes(int bytes) {
    const mib = 1024 * 1024;
    if (bytes >= mib) return '${(bytes / mib).toStringAsFixed(0)} MB';
    if (bytes <= 0) return '';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}
