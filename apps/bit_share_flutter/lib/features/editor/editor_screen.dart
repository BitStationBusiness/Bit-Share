import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/media_formatting.dart';
import '../gallery/media_library.dart';
import 'media_editor.dart';

/// Lite trim/mute editor — no multi-clip timeline, no filters, matching the
/// Telegram/WhatsApp-style scope Bit-Share aims for. Pops `true` once a copy
/// has been saved, so the player above can bounce back to the refreshed grid.
class EditorScreen extends StatefulWidget {
  const EditorScreen({
    required this.item,
    required this.library,
    MediaEditor? editor,
    super.key,
  }) : _editor = editor;

  final MediaItem item;
  final MediaLibrary library;
  final MediaEditor? _editor;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final MediaEditor _editor = widget._editor ?? createMediaEditor();
  VideoPlayerController? _controller;
  MediaEditRequest? _request;
  RangeValues? _range;
  bool _loading = true;
  bool _exporting = false;
  double _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final probed = await _editor.probe(widget.item);
      final duration = probed.duration ?? Duration.zero;
      if (duration <= Duration.zero) {
        setState(() {
          _loading = false;
          _error = 'No se pudo leer la duración de este archivo.';
        });
        return;
      }
      if (probed.kind == MediaKind.video) {
        final controller = probed.path != null
            ? VideoPlayerController.file(File(probed.path!))
            : VideoPlayerController.contentUri(Uri.parse(probed.uri));
        _controller = controller;
        await controller.initialize();
      }
      if (!mounted) return;
      setState(() {
        _request = MediaEditRequest.untouched(source: probed, duration: duration);
        _range = RangeValues(0, duration.inMilliseconds.toDouble());
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No se pudo abrir el editor para este archivo.';
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  MediaEditRequest _effectiveRequest() {
    final range = _range!;
    return _request!.copyWith(
      start: Duration(milliseconds: range.start.round()),
      end: Duration(milliseconds: range.end.round()),
    );
  }

  bool get _canSave => !_exporting && _effectiveRequest().hasChanges;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Editar')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              )
            : _buildEditor(context),
      ),
    );
  }

  Widget _buildEditor(BuildContext context) {
    final request = _request!;
    final range = _range!;
    final controller = _controller;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          if (controller != null && controller.value.isInitialized)
            AspectRatio(
              aspectRatio: controller.value.aspectRatio == 0
                  ? 16 / 9
                  : controller.value.aspectRatio,
              child: VideoPlayer(controller),
            )
          else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Icon(Icons.audiotrack_rounded, size: 88, color: Colors.white38),
            ),
          if (controller != null)
            IconButton(
              iconSize: 38,
              icon: Icon(
                controller.value.isPlaying
                    ? Icons.pause_circle_filled
                    : Icons.play_circle_filled,
              ),
              onPressed: () {
                if (controller.value.isPlaying) {
                  controller.pause();
                } else {
                  unawaited(
                    controller
                        .seekTo(Duration(milliseconds: range.start.round()))
                        .then((_) => controller.play()),
                  );
                }
              },
            ),
          const SizedBox(height: 4),
          Text(
            '${formatDuration(Duration(milliseconds: range.start.round()))} – '
            '${formatDuration(Duration(milliseconds: range.end.round()))} '
            '(de ${formatDuration(request.sourceDuration)})',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          RangeSlider(
            values: range,
            min: 0,
            max: request.sourceDuration.inMilliseconds.toDouble(),
            onChanged: _exporting
                ? null
                : (values) => setState(() => _range = values),
          ),
          if (request.supportsVideoControls)
            SwitchListTile(
              title: const Text('Silenciar'),
              secondary: const Icon(Icons.volume_off_outlined),
              value: request.mute,
              onChanged: _exporting
                  ? null
                  : (value) => setState(() => _request = request.copyWith(mute: value)),
            ),
          const Spacer(),
          if (_exporting) ...[
            Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(value: _progress <= 0 ? null : _progress),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: () => unawaited(_editor.cancel()),
                  child: const Text('Cancelar'),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          FilledButton.icon(
            onPressed: _canSave ? () => unawaited(_save()) : null,
            icon: const Icon(Icons.save_outlined),
            label: Text(_exporting ? 'Guardando…' : 'Guardar copia editada'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final request = _effectiveRequest();
    setState(() {
      _exporting = true;
      _progress = 0;
    });
    try {
      await _editor.export(
        request,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copia editada guardada en la galería de Bit-Share.')),
      );
      Navigator.of(context).pop(true);
    } on MediaEditCancelled {
      if (mounted) setState(() => _exporting = false);
    } on MediaEditException catch (error) {
      if (!mounted) return;
      setState(() => _exporting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}
