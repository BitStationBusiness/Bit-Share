import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
  String? _previewError;

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
      if (!mounted) return;
      setState(() {
        _request = MediaEditRequest.untouched(
          source: probed,
          duration: duration,
        );
        _range = RangeValues(0, duration.inMilliseconds.toDouble());
        _loading = false;
      });
      if (probed.kind != MediaKind.image) {
        await _preparePreview(probed);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No se pudo abrir el editor para este archivo.';
      });
    }
  }

  /// A codec/player failure must never make the editor itself disappear.
  /// FFmpeg can still trim and export formats that the Windows preview plugin
  /// cannot render, so controls are shown with a clear fallback instead.
  Future<void> _preparePreview(MediaItem item) async {
    final controller = item.path != null
        ? VideoPlayerController.file(File(item.path!))
        : VideoPlayerController.contentUri(Uri.parse(item.uri));
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      controller.addListener(_keepPreviewInsideSelection);
      await controller.setLooping(false);
      setState(() => _controller = controller);
    } catch (_) {
      await controller.dispose();
      if (mounted) {
        setState(() {
          _previewError =
              'No se pudo cargar la previsualización, pero puedes editar y exportar el archivo.';
        });
      }
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
          child: LayoutBuilder(
            builder: (context, constraints) {
              // A portrait clip must not grow taller than the window. The
              // rest of the editor remains reachable by scrolling on both a
              // compact Windows window and a small Android handset.
              final previewHeight = math.min(
                320.0,
                math.max(176.0, constraints.maxHeight * .42),
              );
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                children: [
                  if (request.source.kind == MediaKind.video)
                    if (controller != null && controller.value.isInitialized)
                      _buildVideoPreview(
                        context,
                        controller,
                        request.rotation,
                        previewHeight,
                      )
                    else
                      _PreviewFallback(message: _previewError)
                  else
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Icon(
                        Icons.audiotrack_rounded,
                        size: 88,
                        color: Colors.white38,
                      ),
                    ),
                  if (controller != null)
                    _buildPlaybackTimeline(controller, range, request),
                  const SizedBox(height: 4),
                  Text(
                    'Recorte: '
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
                                (preview.value.position <
                                        Duration(
                                          milliseconds: values.start.round(),
                                        ) ||
                                    preview.value.position >
                                        Duration(
                                          milliseconds: values.end.round(),
                                        ))) {
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
                                  () =>
                                      _request = request.copyWith(mute: value),
                                );
                                _updatePreviewVolume(
                                  value ? 0 : request.volume,
                                );
                              },
                      ),
                  ],
                  _buildSelectControls(context, request),
                ],
              );
            },
          ),
        ),
        _buildExportBar(context),
      ],
    );
  }

  Widget _buildVideoPreview(
    BuildContext context,
    VideoPlayerController controller,
    EditorRotation rotation,
    double maxHeight,
  ) {
    final rawAspectRatio = controller.value.aspectRatio;
    final sourceAspectRatio =
        rawAspectRatio.isFinite && rawAspectRatio >= 0.2 && rawAspectRatio <= 5
        ? rawAspectRatio
        : 16 / 9;
    final displayAspectRatio = rotation.swapsAxes
        ? 1 / sourceAspectRatio
        : sourceAspectRatio;
    final availableWidth = MediaQuery.sizeOf(context).width - 32;
    final previewWidth = math.min(
      availableWidth,
      maxHeight * displayAspectRatio,
    );
    return Center(
      child: SizedBox(
        width: previewWidth,
        height: previewWidth / displayAspectRatio,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(
            color: Colors.black,
            child: RotatedBox(
              quarterTurns: rotation.previewQuarterTurns,
              child: RepaintBoundary(
                child: AspectRatio(
                  aspectRatio: sourceAspectRatio,
                  child: VideoPlayer(controller),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaybackTimeline(
    VideoPlayerController controller,
    RangeValues range,
    MediaEditRequest request,
  ) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final start = Duration(milliseconds: range.start.round());
        final end = Duration(milliseconds: range.end.round());
        final position = value.position < start
            ? start
            : value.position > end
            ? end
            : value.position;
        return Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: value.isPlaying ? 'Pausar' : 'Reproducir',
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
                          unawaited(
                            (position >= end
                                    ? controller.seekTo(start)
                                    : Future<void>.value())
                                .then((_) => controller.play()),
                          );
                        },
                ),
                const SizedBox(width: 8),
                Text(
                  '${formatDuration(position)} / '
                  '${formatDuration(request.sourceDuration)}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
            Slider(
              value: position.inMilliseconds.toDouble(),
              min: start.inMilliseconds.toDouble(),
              max: end.inMilliseconds.toDouble(),
              onChanged: _exporting
                  ? null
                  : (milliseconds) => unawaited(
                      controller.seekTo(
                        Duration(milliseconds: milliseconds.round()),
                      ),
                    ),
            ),
          ],
        );
      },
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
                ? (value) {
                    final speed = value ?? 1.0;
                    setState(() => _request = request.copyWith(speed: speed));
                    final controller = _controller;
                    if (controller != null) {
                      unawaited(controller.setPlaybackSpeed(speed));
                    }
                  }
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

class _PreviewFallback extends StatelessWidget {
  const _PreviewFallback({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 150,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.movie_outlined, size: 42, color: Colors.white54),
            if (message != null) ...[
              const SizedBox(height: 10),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
