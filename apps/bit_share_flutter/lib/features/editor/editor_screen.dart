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
      appBar: AppBar(
        toolbarHeight: 52,
        titleSpacing: 0,
        scrolledUnderElevation: 0,
        title: Text(
          'Editar clip',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 620;
        final previewHeight = wide
            ? math.min(420.0, math.max(220.0, constraints.maxHeight - 36))
            : math.min(280.0, math.max(170.0, constraints.maxHeight * .38));
        final preview = _buildPreviewPanel(
          context,
          request,
          controller,
          previewHeight,
        );
        final controls = _buildControlSections(
          context,
          request,
          range,
          controller,
        );

        return Column(
          children: [
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: wide
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(flex: 5, child: preview),
                              const SizedBox(width: 14),
                              Expanded(
                                flex: 6,
                                child: ListView(
                                  padding: EdgeInsets.zero,
                                  children: controls,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                          children: [
                            preview,
                            const SizedBox(height: 10),
                            ...controls,
                          ],
                        ),
                ),
              ),
            ),
            _buildExportBar(context),
          ],
        );
      },
    );
  }

  Widget _buildPreviewPanel(
    BuildContext context,
    MediaEditRequest request,
    VideoPlayerController? controller,
    double maxHeight,
  ) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: .55),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (request.source.kind == MediaKind.video) {
              if (controller != null && controller.value.isInitialized) {
                return _buildVideoPreview(
                  controller,
                  request.rotation,
                  maxHeight,
                  constraints.maxWidth,
                );
              }
              return _PreviewFallback(message: _previewError);
            }
            return SizedBox(
              height: math.min(maxHeight, 180),
              child: const Center(
                child: Icon(
                  Icons.audiotrack_rounded,
                  size: 64,
                  color: Colors.white38,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _buildControlSections(
    BuildContext context,
    MediaEditRequest request,
    RangeValues range,
    VideoPlayerController? controller,
  ) {
    return [
      if (controller != null)
        _EditorSection(
          icon: Icons.content_cut_rounded,
          title: 'RECORTE',
          child: _buildTrimTimeline(controller, range, request),
        ),
      if (controller != null) const SizedBox(height: 10),
      _EditorSection(
        icon: Icons.tune_rounded,
        title: 'AJUSTES',
        child: Column(
          children: [
            if (request.supportsAudioControls) ...[
              _buildVolumeControl(context, request),
              if (request.supportsVideoControls)
                _buildMuteControl(context, request),
            ],
            _buildSelectControls(context, request),
          ],
        ),
      ),
    ];
  }

  Widget _buildVideoPreview(
    VideoPlayerController controller,
    EditorRotation rotation,
    double maxHeight,
    double maxWidth,
  ) {
    final rawAspectRatio = controller.value.aspectRatio;
    final sourceAspectRatio =
        rawAspectRatio.isFinite && rawAspectRatio >= 0.2 && rawAspectRatio <= 5
        ? rawAspectRatio
        : 16 / 9;
    final displayAspectRatio = rotation.swapsAxes
        ? 1 / sourceAspectRatio
        : sourceAspectRatio;
    final previewWidth = math.min(maxWidth, maxHeight * displayAspectRatio);
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
              // The Windows player publishes native texture frames directly.
              // Do not place that texture behind a repaint boundary: it can
              // defer visual updates while the controls are being repainted.
              child: AspectRatio(
                aspectRatio: sourceAspectRatio,
                child: VideoPlayer(controller),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTrimTimeline(
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 36,
              child: Row(
                children: [
                  IconButton(
                    tooltip: value.isPlaying ? 'Pausar' : 'Reproducir',
                    visualDensity: VisualDensity.compact,
                    iconSize: 28,
                    constraints: const BoxConstraints.tightFor(
                      width: 34,
                      height: 34,
                    ),
                    padding: EdgeInsets.zero,
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
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const Spacer(),
                  Text(
                    '${formatDuration(start)} – ${formatDuration(end)}',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 34,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      rangeThumbShape: const RoundRangeSliderThumbShape(
                        enabledThumbRadius: 8,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 14,
                      ),
                    ),
                    child: RangeSlider(
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
                                    Duration(
                                      milliseconds: values.start.round(),
                                    ),
                                  ),
                                );
                              }
                            },
                    ),
                  ),
                  IgnorePointer(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: Colors.transparent,
                        inactiveTrackColor: Colors.transparent,
                        overlayShape: SliderComponentShape.noOverlay,
                        thumbColor: Theme.of(context).colorScheme.onSurface,
                        thumbShape: const _PlayheadThumbShape(),
                      ),
                      child: Slider(
                        value: position.inMilliseconds.toDouble(),
                        min: 0,
                        max: request.sourceDuration.inMilliseconds.toDouble(),
                        onChanged: (_) {},
                      ),
                    ),
                  ),
                ],
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
        SizedBox(
          height: 36,
          child: Row(
            children: [
              const Icon(Icons.volume_up_outlined, size: 18),
              const SizedBox(width: 8),
              SizedBox(
                width: 92,
                child: Text(
                  'Volumen $percentage%',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(trackHeight: 3),
                  child: Slider(
                    value: request.volume,
                    min: 0,
                    max: 2,
                    divisions: 20,
                    label: '$percentage%',
                    onChanged: _exporting || request.mute
                        ? null
                        : (value) {
                            setState(
                              () => _request = request.copyWith(volume: value),
                            );
                            _updatePreviewVolume(value);
                          },
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMuteControl(BuildContext context, MediaEditRequest request) {
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          const Icon(Icons.volume_off_outlined, size: 18),
          const SizedBox(width: 8),
          const Expanded(child: Text('Silenciar vídeo')),
          SizedBox(
            width: 46,
            child: Transform.scale(
              scale: .78,
              child: Switch(
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
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectControls(BuildContext context, MediaEditRequest request) {
    final enabled = !_exporting;
    return Column(
      children: [
        _buildCompactSelect<double>(
          icon: Icons.speed_rounded,
          label: 'Velocidad',
          control: DropdownButton<double>(
            value: request.speed,
            isDense: true,
            style: Theme.of(context).textTheme.bodyMedium,
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
          _buildCompactSelect<EditorRotation>(
            icon: Icons.rotate_right_rounded,
            label: 'Rotación',
            control: DropdownButton<EditorRotation>(
              value: request.rotation,
              isDense: true,
              style: Theme.of(context).textTheme.bodyMedium,
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
          _buildCompactSelect<EditorQuality>(
            icon: Icons.high_quality_outlined,
            label: 'Calidad de salida',
            control: DropdownButton<EditorQuality>(
              value: request.quality,
              isDense: true,
              style: Theme.of(context).textTheme.bodyMedium,
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

  Widget _buildCompactSelect<T>({
    required IconData icon,
    required String label,
    required Widget control,
  }) {
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          control,
        ],
      ),
    );
  }

  Widget _buildExportBar(BuildContext context) {
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth >= 620;
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (_exporting) ...[
                  Row(
                    children: [
                      Expanded(
                        child: LinearProgressIndicator(
                          value: _progress <= 0 ? null : _progress,
                        ),
                      ),
                      const SizedBox(width: 10),
                      TextButton(
                        onPressed: () => unawaited(_editor.cancel()),
                        child: const Text('Cancelar'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                SizedBox(
                  width: compact ? 240 : double.infinity,
                  child: FilledButton.icon(
                    onPressed: _canSave ? () => unawaited(_save()) : null,
                    icon: const Icon(Icons.save_outlined, size: 17),
                    label: Text(_exporting ? 'Guardando…' : 'Guardar copia'),
                  ),
                ),
              ],
            ),
          );
        },
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

class _EditorSection extends StatelessWidget {
  const _EditorSection({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .55)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 15, color: colors.primary),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .8,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            child,
          ],
        ),
      ),
    );
  }
}

/// Reserves the same horizontal geometry as each trim handle but paints only
/// a small dot. This keeps the playhead exactly aligned with the RangeSlider
/// track without visually competing with the two edit handles.
class _PlayheadThumbShape extends SliderComponentShape {
  const _PlayheadThumbShape();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(16, 16);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    context.canvas.drawCircle(
      center,
      3.5,
      Paint()..color = sliderTheme.thumbColor ?? Colors.white,
    );
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
