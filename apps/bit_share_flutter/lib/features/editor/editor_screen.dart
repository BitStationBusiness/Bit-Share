import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/media_formatting.dart';
import '../gallery/media_library.dart';
import 'media_editor.dart';

/// Focused single-clip editor. It intentionally stays closer to Telegram and
/// WhatsApp than to a desktop NLE: trim, volume, mute, speed, rotation and
/// output size are immediately usable, while the original is never changed.
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
      if (probed.kind != MediaKind.image) {
        final controller = probed.path != null
            ? VideoPlayerController.file(File(probed.path!))
            : VideoPlayerController.contentUri(Uri.parse(probed.uri));
        _controller = controller;
        await controller.initialize();
        controller.addListener(_keepPreviewInsideSelection);
      }
      if (!mounted) return;
      setState(() {
        _request = MediaEditRequest.untouched(
          source: probed,
          duration: duration,
        );
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
    _controller?.removeListener(_keepPreviewInsideSelection);
    _controller?.dispose();
    super.dispose();
  }

  /// The trim handles define the playable preview too. Without this guard a
  /// preview continues past the right handle, which makes a user think the
  /// exported cut will be longer than it actually is.
  void _keepPreviewInsideSelection() {
    final controller = _controller;
    final range = _range;
    if (controller == null || range == null || !controller.value.isPlaying) {
      return;
    }
    final end = Duration(milliseconds: range.end.round());
    if (controller.value.position >= end) {
      unawaited(controller.pause());
      unawaited(controller.seekTo(end));
    }
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
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            children: [
              if (request.source.kind == MediaKind.video &&
                  controller != null &&
                  controller.value.isInitialized)
                AspectRatio(
                  aspectRatio: controller.value.aspectRatio == 0
                      ? 16 / 9
                      : controller.value.aspectRatio,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: VideoPlayer(controller),
                  ),
                )
              else
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Icon(
                    Icons.audiotrack_rounded,
                    size: 88,
                    color: Colors.white38,
                  ),
                ),
              if (controller != null) _buildPlaybackButton(controller, range),
              const SizedBox(height: 4),
              Text(
                '${formatDuration(Duration(milliseconds: range.start.round()))} – '
                '${formatDuration(Duration(milliseconds: range.end.round()))} '
                '(de ${formatDuration(request.sourceDuration)})',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              RangeSlider(
                values: range,
                min: 0,
                max: request.sourceDuration.inMilliseconds.toDouble(),
                onChanged: _exporting
                    ? null
                    : (values) {
                        setState(() => _range = values);
                        final preview = _controller;
                        if (preview != null &&
                            preview.value.position >
                                Duration(milliseconds: values.end.round())) {
                          unawaited(
                            preview.seekTo(
                              Duration(milliseconds: values.start.round()),
                            ),
                          );
                        }
                      },
              ),
              const Divider(height: 28),
              if (request.supportsAudioControls) ...[
                _buildVolumeControl(context, request),
                if (request.supportsVideoControls)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Silenciar vídeo'),
                    secondary: const Icon(Icons.volume_off_outlined),
                    value: request.mute,
                    onChanged: _exporting
                        ? null
                        : (value) {
                            setState(
                              () => _request = request.copyWith(mute: value),
                            );
                            _updatePreviewVolume(value ? 0 : request.volume);
                          },
                  ),
              ],
              _buildSelectControls(context, request),
            ],
          ),
        ),
        _buildExportBar(context),
      ],
    );
  }

  Widget _buildPlaybackButton(
    VideoPlayerController controller,
    RangeValues range,
  ) {
    return Center(
      child: ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: controller,
        builder: (context, value, _) => IconButton(
          iconSize: 42,
          icon: Icon(
            value.isPlaying
                ? Icons.pause_circle_filled
                : Icons.play_circle_filled,
          ),
          onPressed: _exporting
              ? null
              : () {
                  if (value.isPlaying) {
                    unawaited(controller.pause());
                    return;
                  }
                  final start = Duration(milliseconds: range.start.round());
                  final end = Duration(milliseconds: range.end.round());
                  final position = controller.value.position;
                  unawaited(
                    (position < start || position >= end
                            ? controller.seekTo(start)
                            : Future<void>.value())
                        .then((_) => controller.play()),
                  );
                },
        ),
      ),
    );
  }

  Widget _buildVolumeControl(BuildContext context, MediaEditRequest request) {
    final percentage = (request.volume * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.volume_up_outlined),
            const SizedBox(width: 12),
            Expanded(child: Text('Volumen $percentage%')),
            Text(
              request.mute ? 'Silenciado' : '',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        Slider(
          value: request.volume,
          min: 0,
          max: 2,
          divisions: 20,
          label: '$percentage%',
          onChanged: _exporting || request.mute
              ? null
              : (value) {
                  setState(() => _request = request.copyWith(volume: value));
                  _updatePreviewVolume(value);
                },
        ),
      ],
    );
  }

  Widget _buildSelectControls(BuildContext context, MediaEditRequest request) {
    final enabled = !_exporting;
    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.speed_rounded),
          title: const Text('Velocidad'),
          trailing: DropdownButton<double>(
            value: request.speed,
            onChanged: enabled
                ? (value) => setState(
                    () => _request = request.copyWith(speed: value ?? 1.0),
                  )
                : null,
            items: editorSpeeds
                .map(
                  (speed) =>
                      DropdownMenuItem(value: speed, child: Text('$speed×')),
                )
                .toList(growable: false),
          ),
        ),
        if (request.supportsVideoControls) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.rotate_right_rounded),
            title: const Text('Rotación'),
            trailing: DropdownButton<EditorRotation>(
              value: request.rotation,
              onChanged: enabled
                  ? (value) => setState(
                      () => _request = request.copyWith(
                        rotation: value ?? EditorRotation.none,
                      ),
                    )
                  : null,
              items: EditorRotation.values
                  .map(
                    (rotation) => DropdownMenuItem(
                      value: rotation,
                      child: Text(rotation.label),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.high_quality_outlined),
            title: const Text('Calidad de salida'),
            trailing: DropdownButton<EditorQuality>(
              value: request.quality,
              onChanged: enabled
                  ? (value) => setState(
                      () => _request = request.copyWith(
                        quality: value ?? EditorQuality.original,
                      ),
                    )
                  : null,
              items: EditorQuality.values
                  .map(
                    (quality) => DropdownMenuItem(
                      value: quality,
                      child: Text(quality.label),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildExportBar(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_exporting) ...[
              Row(
                children: [
                  Expanded(
                    child: LinearProgressIndicator(
                      value: _progress <= 0 ? null : _progress,
                    ),
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
      ),
    );
  }

  void _updatePreviewVolume(double volume) {
    final controller = _controller;
    if (controller == null) return;
    // video_player intentionally caps preview gain at 100%. FFmpeg still
    // applies the selected 0–200% volume during export.
    unawaited(controller.setVolume(volume.clamp(0.0, 1.0).toDouble()));
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
        const SnackBar(
          content: Text('Copia editada guardada en la galería de Bit-Share.'),
        ),
      );
      Navigator.of(context).pop(true);
    } on MediaEditCancelled {
      if (mounted) setState(() => _exporting = false);
    } on MediaEditException catch (error) {
      if (!mounted) return;
      setState(() => _exporting = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}
