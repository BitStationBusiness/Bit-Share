import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../core/media_formatting.dart';
import '../../core/windows_window_controls.dart';
import '../gallery/media_library.dart';
import 'media_editor.dart';
import 'preview_source.dart';

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
  bool _preparingPreview = false;
  Duration? _timelineScrubPosition;
  Timer? _timelineSeekDebounce;
  bool _resumeAfterTimelineScrub = false;
  bool _windowFullscreen = false;

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
    if (mounted) setState(() => _preparingPreview = true);
    final source = await prepareEditorPreview(item);
    final controller = source.path != null
        ? VideoPlayerController.file(File(source.path!))
        : VideoPlayerController.contentUri(Uri.parse(source.uri));
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      controller.addListener(_keepPreviewInsideSelection);
      await controller.setLooping(false);
      setState(() {
        _controller = controller;
        _preparingPreview = false;
      });
    } catch (_) {
      await controller.dispose();
      if (mounted) {
        setState(() {
          _preparingPreview = false;
          _previewError =
              'No se pudo cargar la previsualización, pero puedes editar y exportar el archivo.';
        });
      }
    }
  }

  @override
  void dispose() {
    _timelineSeekDebounce?.cancel();
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
        actions: [
          if (WindowsWindowControls.isSupported)
            IconButton(
              tooltip: _windowFullscreen
                  ? 'Salir de pantalla completa (F11)'
                  : 'Pantalla completa (F11)',
              visualDensity: VisualDensity.compact,
              onPressed: () => unawaited(_toggleWindowFullscreen()),
              icon: Icon(
                _windowFullscreen
                    ? Icons.fullscreen_exit_rounded
                    : Icons.fullscreen_rounded,
                size: 20,
              ),
            ),
        ],
      ),
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.f11): () =>
              unawaited(_toggleWindowFullscreen()),
        },
        child: Focus(
          autofocus: true,
          child: SafeArea(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  )
                : _buildEditor(context),
          ),
        ),
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
              return _PreviewFallback(
                message: _previewError,
                loading: _preparingPreview,
              );
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
        final rawPosition = _timelineScrubPosition ?? value.position;
        final position = rawPosition < start
            ? start
            : rawPosition > end
            ? end
            : rawPosition;
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
            _TrimTimelineBar(
              durationMilliseconds: request.sourceDuration.inMilliseconds,
              range: range,
              positionMilliseconds: position.inMilliseconds.toDouble(),
              enabled: !_exporting,
              onRangeChanged: (values) => _updateTrimRange(controller, values),
              onSeekStart: (milliseconds) =>
                  _beginTimelineScrub(controller, milliseconds),
              onSeek: (milliseconds) =>
                  _updateTimelineScrub(controller, milliseconds),
              onSeekEnd: (milliseconds) =>
                  unawaited(_finishTimelineScrub(controller, milliseconds)),
            ),
          ],
        );
      },
    );
  }

  void _updateTrimRange(VideoPlayerController controller, RangeValues values) {
    setState(() => _range = values);
    final position = controller.value.position.inMilliseconds.toDouble();
    if (position < values.start || position > values.end) {
      final target = position < values.start ? values.start : values.end;
      unawaited(controller.seekTo(Duration(milliseconds: target.round())));
    }
  }

  void _beginTimelineScrub(
    VideoPlayerController controller,
    double milliseconds,
  ) {
    _resumeAfterTimelineScrub = controller.value.isPlaying;
    if (controller.value.isPlaying) unawaited(controller.pause());
    setState(
      () =>
          _timelineScrubPosition = Duration(milliseconds: milliseconds.round()),
    );
  }

  void _updateTimelineScrub(
    VideoPlayerController controller,
    double milliseconds,
  ) {
    final position = Duration(milliseconds: milliseconds.round());
    setState(() => _timelineScrubPosition = position);
    _timelineSeekDebounce?.cancel();
    _timelineSeekDebounce = Timer(
      const Duration(milliseconds: 35),
      () => unawaited(controller.seekTo(position)),
    );
  }

  Future<void> _finishTimelineScrub(
    VideoPlayerController controller,
    double milliseconds,
  ) async {
    _timelineSeekDebounce?.cancel();
    final shouldResume = _resumeAfterTimelineScrub;
    _resumeAfterTimelineScrub = false;
    await controller.seekTo(Duration(milliseconds: milliseconds.round()));
    if (shouldResume) await controller.play();
    if (mounted) setState(() => _timelineScrubPosition = null);
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

  Future<void> _toggleWindowFullscreen() async {
    if (!WindowsWindowControls.isSupported) return;
    try {
      final fullscreen = await WindowsWindowControls.setFullscreen(
        !_windowFullscreen,
      );
      if (mounted) setState(() => _windowFullscreen = fullscreen);
    } on PlatformException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Windows no pudo cambiar a pantalla completa.'),
        ),
      );
    }
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

enum _TimelineDragTarget { start, playhead, end }

/// One compact timeline owns all three interactions instead of stacking an
/// inert playhead above a RangeSlider. The upper playhead can be dragged or
/// the track can be clicked to seek; the two lower handles edit the cut.
class _TrimTimelineBar extends StatefulWidget {
  const _TrimTimelineBar({
    required this.durationMilliseconds,
    required this.range,
    required this.positionMilliseconds,
    required this.enabled,
    required this.onRangeChanged,
    required this.onSeekStart,
    required this.onSeek,
    required this.onSeekEnd,
  });

  final int durationMilliseconds;
  final RangeValues range;
  final double positionMilliseconds;
  final bool enabled;
  final ValueChanged<RangeValues> onRangeChanged;
  final ValueChanged<double> onSeekStart;
  final ValueChanged<double> onSeek;
  final ValueChanged<double> onSeekEnd;

  @override
  State<_TrimTimelineBar> createState() => _TrimTimelineBarState();
}

class _TrimTimelineBarState extends State<_TrimTimelineBar> {
  _TimelineDragTarget? _target;
  double? _lastSeekValue;

  double _valueForDx(double dx, double width) {
    final usable = math.max(1.0, width - 20);
    final fraction = ((dx - 10) / usable).clamp(0.0, 1.0);
    return fraction * widget.durationMilliseconds;
  }

  double _dxForValue(double value, double width) {
    final duration = math.max(1, widget.durationMilliseconds);
    return 10 + (value / duration).clamp(0.0, 1.0) * (width - 20);
  }

  void _startDrag(DragStartDetails details, double width) {
    if (!widget.enabled) return;
    final dx = details.localPosition.dx;
    final startDx = _dxForValue(widget.range.start, width);
    final endDx = _dxForValue(widget.range.end, width);
    final positionDx = _dxForValue(widget.positionMilliseconds, width);
    final startDistance = (dx - startDx).abs();
    final endDistance = (dx - endDx).abs();
    final playheadDistance = (dx - positionDx).abs();

    // Trim handles live in the lower half; the upper half always belongs to
    // the playhead. This removes ambiguity when playhead and start coincide.
    if (details.localPosition.dy >= 18 &&
        math.min(startDistance, endDistance) <= 18 &&
        math.min(startDistance, endDistance) <= playheadDistance) {
      _target = startDistance <= endDistance
          ? _TimelineDragTarget.start
          : _TimelineDragTarget.end;
    } else {
      _target = _TimelineDragTarget.playhead;
      final value = _valueForDx(
        dx,
        width,
      ).clamp(widget.range.start, widget.range.end);
      _lastSeekValue = value;
      widget.onSeekStart(value);
    }
  }

  void _updateDrag(DragUpdateDetails details, double width) {
    if (!widget.enabled) return;
    final rawValue = _valueForDx(details.localPosition.dx, width);
    switch (_target) {
      case _TimelineDragTarget.start:
        widget.onRangeChanged(
          RangeValues(rawValue.clamp(0, widget.range.end), widget.range.end),
        );
      case _TimelineDragTarget.end:
        widget.onRangeChanged(
          RangeValues(
            widget.range.start,
            rawValue.clamp(
              widget.range.start,
              widget.durationMilliseconds.toDouble(),
            ),
          ),
        );
      case _TimelineDragTarget.playhead:
        final value = rawValue.clamp(widget.range.start, widget.range.end);
        _lastSeekValue = value;
        widget.onSeek(value);
      case null:
        break;
    }
  }

  void _endDrag(DragEndDetails details) {
    if (_target == _TimelineDragTarget.playhead) {
      widget.onSeekEnd(_lastSeekValue ?? widget.positionMilliseconds);
    }
    _target = null;
    _lastSeekValue = null;
  }

  void _seekFromTap(TapUpDetails details, double width) {
    if (!widget.enabled) return;
    final value = _valueForDx(
      details.localPosition.dx,
      width,
    ).clamp(widget.range.start, widget.range.end);
    widget.onSeekStart(value);
    widget.onSeek(value);
    widget.onSeekEnd(value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Línea de tiempo y recorte',
      value: formatDuration(
        Duration(milliseconds: widget.positionMilliseconds.round()),
      ),
      child: SizedBox(
        height: 42,
        child: LayoutBuilder(
          builder: (context, constraints) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) => _seekFromTap(details, constraints.maxWidth),
            onHorizontalDragStart: (details) =>
                _startDrag(details, constraints.maxWidth),
            onHorizontalDragUpdate: (details) =>
                _updateDrag(details, constraints.maxWidth),
            onHorizontalDragEnd: _endDrag,
            child: MouseRegion(
              cursor: widget.enabled
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              child: CustomPaint(
                painter: _TrimTimelinePainter(
                  durationMilliseconds: widget.durationMilliseconds,
                  range: widget.range,
                  positionMilliseconds: widget.positionMilliseconds,
                  enabled: widget.enabled,
                  activeColor: colors.primary,
                  inactiveColor: colors.outlineVariant,
                  playheadColor: colors.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TrimTimelinePainter extends CustomPainter {
  const _TrimTimelinePainter({
    required this.durationMilliseconds,
    required this.range,
    required this.positionMilliseconds,
    required this.enabled,
    required this.activeColor,
    required this.inactiveColor,
    required this.playheadColor,
  });

  final int durationMilliseconds;
  final RangeValues range;
  final double positionMilliseconds;
  final bool enabled;
  final Color activeColor;
  final Color inactiveColor;
  final Color playheadColor;

  double _x(double value, double width) {
    final duration = math.max(1, durationMilliseconds);
    return 10 + (value / duration).clamp(0.0, 1.0) * (width - 20);
  }

  @override
  void paint(Canvas canvas, Size size) {
    const trackY = 25.0;
    final startX = _x(range.start, size.width);
    final endX = _x(range.end, size.width);
    final playheadX = _x(positionMilliseconds, size.width);
    final opacity = enabled ? 1.0 : .45;

    canvas.drawLine(
      const Offset(10, trackY),
      Offset(size.width - 10, trackY),
      Paint()
        ..color = inactiveColor.withValues(alpha: .65 * opacity)
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      Offset(startX, trackY),
      Offset(endX, trackY),
      Paint()
        ..color = activeColor.withValues(alpha: opacity)
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round,
    );
    final handlePaint = Paint()..color = activeColor.withValues(alpha: opacity);
    canvas.drawCircle(Offset(startX, trackY), 8, handlePaint);
    canvas.drawCircle(Offset(endX, trackY), 8, handlePaint);

    final playheadPaint = Paint()
      ..color = playheadColor.withValues(alpha: opacity)
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(playheadX, 7),
      Offset(playheadX, trackY + 8),
      playheadPaint,
    );
    canvas.drawCircle(Offset(playheadX, 7), 4, playheadPaint);
  }

  @override
  bool shouldRepaint(covariant _TrimTimelinePainter oldDelegate) =>
      oldDelegate.durationMilliseconds != durationMilliseconds ||
      oldDelegate.range != range ||
      oldDelegate.positionMilliseconds != positionMilliseconds ||
      oldDelegate.enabled != enabled ||
      oldDelegate.activeColor != activeColor ||
      oldDelegate.inactiveColor != inactiveColor ||
      oldDelegate.playheadColor != playheadColor;
}

class _PreviewFallback extends StatelessWidget {
  const _PreviewFallback({this.message, this.loading = false});

  final String? message;
  final bool loading;

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
            if (loading)
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            else
              const Icon(Icons.movie_outlined, size: 42, color: Colors.white54),
            if (loading) ...[
              const SizedBox(height: 10),
              Text(
                'Preparando una vista previa fluida…',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
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
