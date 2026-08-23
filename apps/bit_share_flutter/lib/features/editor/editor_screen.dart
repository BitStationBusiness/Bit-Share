import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
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

  /// Android is driven by fingers and Windows by a mouse, and the two want
  /// different hit areas: 36px rows are comfortable with a cursor but fall
  /// under the 48dp touch guidance. Everything sizing-related keys off this.
  /// Read from [defaultTargetPlatform] rather than `Platform.isAndroid` so a
  /// widget test can pin the platform and exercise the real touch sizes.
  bool get _touchLayout => defaultTargetPlatform == TargetPlatform.android;

  /// Stands in for the player when no preview could be created, so the trim
  /// bar has something to listen to. Its value never changes: there is no
  /// playback to follow, only handles to drag.
  final ValueNotifier<VideoPlayerValue> _idlePlayerValue = ValueNotifier(
    const VideoPlayerValue(duration: Duration.zero),
  );

  /// Appends the keyboard shortcut to a label, but only where a keyboard is
  /// actually expected. A wide window is not the same thing as a physical
  /// keyboard: an Android tablet in landscape is wide and has no Ctrl key,
  /// and promising one there is just noise.
  String _withShortcut(String label, String key) =>
      _touchLayout ? label : '$label ($key)';

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
    // Everything here is inside the guard, including building the preview
    // source. It used to sit outside, so a failure there escaped to
    // _prepare()'s catch and replaced the whole editor with an error page —
    // the exact opposite of what this method promises.
    VideoPlayerController? controller;
    try {
      final source = await prepareEditorPreview(item);
      controller = source.path != null
          ? VideoPlayerController.file(File(source.path!))
          : VideoPlayerController.contentUri(Uri.parse(source.uri));
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
      await controller?.dispose();
      if (mounted) {
        setState(() {
          _preparingPreview = false;
          _previewError =
              'No se pudo cargar la previsualización, pero puedes '
              'recortar y exportar el archivo.';
        });
      }
    }
  }

  @override
  void dispose() {
    _timelineSeekDebounce?.cancel();
    // Leaving mid-export would otherwise strand the ffmpeg process: nothing
    // else calls cancel(), and the screen that owned it is already gone.
    if (_exporting) unawaited(_editor.cancel());
    _idlePlayerValue.dispose();
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

  bool get _canSave => !_exporting && _effectiveRequest().isExportable;

  @override
  Widget build(BuildContext context) {
    final request = _request;
    final dirty = request != null && _effectiveRequest().hasChanges;
    return PopScope(
      // Leaving with pending edits used to discard them without a word. The
      // export is the only thing that persists anything, so the confirmation
      // is the user's single chance to notice.
      canPop: !dirty || _exporting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_confirmDiscard());
      },
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 52,
          titleSpacing: 0,
          scrolledUnderElevation: 0,
          title: Text(
            'Editar clip',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          actions: [
            if (request != null)
              IconButton(
                tooltip: 'Descartar los cambios',
                visualDensity: VisualDensity.compact,
                onPressed: dirty && !_exporting ? _resetEdits : null,
                icon: const Icon(Icons.restart_alt_rounded, size: 20),
              ),
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
          bindings: _shortcutBindings(),
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
      ),
    );
  }

  /// Desktop editing is keyboard-first. These mirror the bindings a user
  /// already knows from other editors, so the mouse is never the only way to
  /// reach a control.
  Map<ShortcutActivator, VoidCallback> _shortcutBindings() {
    return {
      const SingleActivator(LogicalKeyboardKey.f11): () =>
          unawaited(_toggleWindowFullscreen()),
      const SingleActivator(LogicalKeyboardKey.space): _togglePlayback,
      const SingleActivator(LogicalKeyboardKey.keyK): _togglePlayback,
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
          _seekBy(const Duration(seconds: -1)),
      const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
          _seekBy(const Duration(seconds: 1)),
      const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): () =>
          _seekBy(const Duration(seconds: -10)),
      const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): () =>
          _seekBy(const Duration(seconds: 10)),
      const SingleActivator(LogicalKeyboardKey.keyJ): () =>
          _seekBy(const Duration(seconds: -10)),
      const SingleActivator(LogicalKeyboardKey.keyL): () =>
          _seekBy(const Duration(seconds: 10)),
      const SingleActivator(LogicalKeyboardKey.keyI): _setStartAtPlayhead,
      const SingleActivator(LogicalKeyboardKey.keyO): _setEndAtPlayhead,
      const SingleActivator(LogicalKeyboardKey.home): () =>
          _seekTo(Duration(milliseconds: (_range?.start ?? 0).round())),
      const SingleActivator(LogicalKeyboardKey.end): () =>
          _seekTo(Duration(milliseconds: (_range?.end ?? 0).round())),
      const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
        if (_canSave) unawaited(_save());
      },
    };
  }

  Widget _buildEditor(BuildContext context) {
    final request = _request!;
    final range = _range!;
    final controller = _controller;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 620;
        // The old 420px ceiling was tuned for a small window and left a
        // tablet in landscape showing a postage-stamp preview surrounded by
        // several hundred pixels of nothing. The preview may now use the
        // height it is actually given; the aspect ratio still bounds the
        // width, so a landscape clip never grows past its column.
        final previewHeight = wide
            ? math.max(240.0, constraints.maxHeight - 24)
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
                  // 920 kept the preview around 400px wide on a normal
                  // desktop window, with the rest of the screen empty. The
                  // cap still exists so the controls do not stretch across
                  // an ultrawide monitor, just further out.
                  constraints: const BoxConstraints(maxWidth: 1320),
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
      // Cutting only needs the duration, which probe() already provided.
      // Gating this on the preview meant an unsupported codec removed the
      // editor's whole reason for existing while still claiming the file
      // could be edited.
      _EditorSection(
        icon: Icons.content_cut_rounded,
        title: 'RECORTE',
        child: _buildTrimTimeline(controller, range, request),
      ),
      const SizedBox(height: 10),
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
    // heightFactor: 1 makes this hug the video instead of expanding to the
    // full constraint, which is what padded the surrounding card out to a
    // height its content never used.
    return Align(
      heightFactor: 1,
      child: SizedBox(
        width: previewWidth,
        height: previewWidth / displayAspectRatio,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          // Tapping the image to start and stop is the one gesture every
          // video surface has taught users to expect; without it the only
          // way to play was the small button under the timeline.
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _exporting ? null : _togglePlayback,
            child: MouseRegion(
              cursor: _exporting
                  ? SystemMouseCursors.basic
                  : SystemMouseCursors.click,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: Colors.black,
                    child: RotatedBox(
                      quarterTurns: rotation.previewQuarterTurns,
                      // The Windows player publishes native texture frames
                      // directly. Do not place that texture behind a repaint
                      // boundary: it can defer visual updates while the
                      // controls are being repainted.
                      child: AspectRatio(
                        aspectRatio: sourceAspectRatio,
                        child: VideoPlayer(controller),
                      ),
                    ),
                  ),
                  // Only the badge listens to the controller. Rebuilding the
                  // VideoPlayer above on every position tick would put the
                  // native texture through exactly the repaint churn the
                  // comment there warns about.
                  ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: controller,
                    builder: (context, value, child) => AnimatedOpacity(
                      opacity: value.isPlaying ? 0 : 1,
                      duration: const Duration(milliseconds: 140),
                      child: IgnorePointer(child: child),
                    ),
                    child: const Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black45,
                          shape: BoxShape.circle,
                        ),
                        child: Padding(
                          padding: EdgeInsets.all(10),
                          child: Icon(
                            Icons.play_arrow_rounded,
                            size: 34,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTrimTimeline(
    VideoPlayerController? controller,
    RangeValues range,
    MediaEditRequest request,
  ) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller ?? _idlePlayerValue,
      builder: (context, value, _) {
        final start = Duration(milliseconds: range.start.round());
        final end = Duration(milliseconds: range.end.round());
        final rawPosition = _timelineScrubPosition ?? value.position;
        final position = rawPosition < start
            ? start
            : rawPosition > end
            ? end
            : rawPosition;
        final controlHeight = _touchLayout ? 44.0 : 36.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: controlHeight,
              child: Row(
                children: [
                  IconButton(
                    tooltip: _withShortcut(
                      value.isPlaying ? 'Pausar' : 'Reproducir',
                      'Espacio',
                    ),
                    visualDensity: VisualDensity.compact,
                    iconSize: _touchLayout ? 34 : 28,
                    constraints: BoxConstraints.tightFor(
                      width: controlHeight,
                      height: controlHeight,
                    ),
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      value.isPlaying
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_filled,
                    ),
                    onPressed: _exporting || controller == null
                        ? null
                        : _togglePlayback,
                  ),
                  const SizedBox(width: 8),
                  // Flexible, not fixed: a 12-minute clip makes this string
                  // half again as long as a 19-second one, and on a 360dp
                  // phone that difference overflowed the row.
                  Flexible(
                    child: Text(
                      '${formatDuration(position)} / '
                      '${formatDuration(request.sourceDuration)}',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                ],
              ),
            ),
            _TrimTimelineBar(
              durationMilliseconds: request.sourceDuration.inMilliseconds,
              range: range,
              positionMilliseconds: position.inMilliseconds.toDouble(),
              enabled: !_exporting,
              touchLayout: _touchLayout,
              onRangeChanged: (values) => _updateTrimRange(controller, values),
              onSeekStart: (milliseconds) =>
                  _beginTimelineScrub(controller, milliseconds),
              onSeek: (milliseconds) =>
                  _updateTimelineScrub(controller, milliseconds),
              onSeekEnd: (milliseconds) =>
                  unawaited(_finishTimelineScrub(controller, milliseconds)),
            ),
            const SizedBox(height: 6),
            // Each one shows where its handle sits and moves it to the
            // playhead when pressed — the only precise way to cut a long
            // clip, where a pixel of the bar can be several seconds. Given
            // half the width each, no clip length can push them out of view.
            Row(
              children: [
                Expanded(
                  child: _TrimEdgeButton(
                    label: 'Inicio',
                    value: formatDuration(start),
                    tooltip: _withShortcut('Cortar el inicio aquí', 'I'),
                    height: controlHeight,
                    onPressed: _exporting || controller == null
                        ? null
                        : _setStartAtPlayhead,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _TrimEdgeButton(
                    label: 'Fin',
                    value: formatDuration(end),
                    tooltip: _withShortcut('Cortar el final aquí', 'O'),
                    height: controlHeight,
                    onPressed: _exporting || controller == null
                        ? null
                        : _setEndAtPlayhead,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  void _updateTrimRange(VideoPlayerController? controller, RangeValues values) {
    final clamped = _clampSelection(values);
    setState(() => _range = clamped);
    if (controller == null) return;
    final position = controller.value.position.inMilliseconds.toDouble();
    if (position < clamped.start || position > clamped.end) {
      final target = position < clamped.start ? clamped.start : clamped.end;
      unawaited(controller.seekTo(Duration(milliseconds: target.round())));
    }
  }

  /// Keeps the two handles at least [editorMinimumSelection] apart, pushing
  /// whichever one is being dragged rather than the one the user is holding
  /// still, so a drag never silently moves the opposite end.
  RangeValues _clampSelection(RangeValues values, {bool movingStart = true}) {
    final total = _request!.sourceDuration.inMilliseconds.toDouble();
    final minimum = editorMinimumSelection.inMilliseconds.toDouble();
    var start = values.start.clamp(0.0, total);
    var end = values.end.clamp(0.0, total);
    if (end - start >= minimum) return RangeValues(start, end);
    if (movingStart) {
      start = math.min(start, math.max(0.0, total - minimum));
      end = math.min(total, start + minimum);
    } else {
      end = math.max(end, math.min(total, minimum));
      start = math.max(0.0, end - minimum);
    }
    return RangeValues(start, end);
  }

  void _togglePlayback() {
    final controller = _controller;
    final range = _range;
    if (controller == null || range == null || _exporting) return;
    if (controller.value.isPlaying) {
      unawaited(controller.pause());
      return;
    }
    final end = Duration(milliseconds: range.end.round());
    final start = Duration(milliseconds: range.start.round());
    // Restarting from the cut's beginning is what the play button already
    // does; the keyboard path must not behave differently.
    final rewind = controller.value.position >= end
        ? controller.seekTo(start)
        : Future<void>.value();
    unawaited(rewind.then((_) => controller.play()));
  }

  void _seekBy(Duration delta) {
    final controller = _controller;
    if (controller == null) return;
    _seekTo(controller.value.position + delta);
  }

  void _seekTo(Duration position) {
    final controller = _controller;
    final range = _range;
    if (controller == null || range == null || _exporting) return;
    final start = Duration(milliseconds: range.start.round());
    final end = Duration(milliseconds: range.end.round());
    final target = position < start ? start : (position > end ? end : position);
    unawaited(controller.seekTo(target));
  }

  /// Moves the near handle to wherever the playhead sits. Dragging a handle
  /// on a long clip is guesswork — a pixel can be several seconds — so the
  /// playhead, which can be positioned exactly, doubles as the precise way
  /// to set the cut.
  void _setStartAtPlayhead() {
    final controller = _controller;
    final range = _range;
    if (controller == null || range == null || _exporting) return;
    final position = controller.value.position.inMilliseconds.toDouble();
    setState(
      () => _range = _clampSelection(
        RangeValues(position, range.end),
        movingStart: true,
      ),
    );
  }

  void _setEndAtPlayhead() {
    final controller = _controller;
    final range = _range;
    if (controller == null || range == null || _exporting) return;
    final position = controller.value.position.inMilliseconds.toDouble();
    setState(
      () => _range = _clampSelection(
        RangeValues(range.start, position),
        movingStart: false,
      ),
    );
  }

  void _resetEdits() {
    final request = _request;
    if (request == null || _exporting) return;
    final duration = request.sourceDuration;
    setState(() {
      _request = MediaEditRequest.untouched(
        source: request.source,
        duration: duration,
      );
      _range = RangeValues(0, duration.inMilliseconds.toDouble());
    });
    final controller = _controller;
    if (controller != null) {
      unawaited(controller.setPlaybackSpeed(1.0));
      unawaited(controller.setVolume(1));
      unawaited(controller.seekTo(Duration.zero));
    }
  }

  Future<void> _confirmDiscard() async {
    final navigator = Navigator.of(context);
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Descartar los cambios'),
        content: const Text(
          'Has ajustado este clip pero aún no has guardado la copia. '
          'Si sales ahora se perderán los ajustes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Seguir editando'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Salir sin guardar'),
          ),
        ],
      ),
    );
    if (discard == true && navigator.mounted) navigator.pop();
  }

  void _beginTimelineScrub(
    VideoPlayerController? controller,
    double milliseconds,
  ) {
    if (controller == null) return;
    _resumeAfterTimelineScrub = controller.value.isPlaying;
    if (controller.value.isPlaying) unawaited(controller.pause());
    setState(
      () =>
          _timelineScrubPosition = Duration(milliseconds: milliseconds.round()),
    );
  }

  void _updateTimelineScrub(
    VideoPlayerController? controller,
    double milliseconds,
  ) {
    if (controller == null) return;
    final position = Duration(milliseconds: milliseconds.round());
    setState(() => _timelineScrubPosition = position);
    _timelineSeekDebounce?.cancel();
    _timelineSeekDebounce = Timer(
      const Duration(milliseconds: 35),
      () => unawaited(controller.seekTo(position)),
    );
  }

  Future<void> _finishTimelineScrub(
    VideoPlayerController? controller,
    double milliseconds,
  ) async {
    if (controller == null) return;
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
                // 92 was too tight for "Volumen 100%", which wrapped onto a
                // second line inside a row only 36px tall.
                width: 120,
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
          final wide = constraints.maxWidth >= 620;
          final saveButton = SizedBox(
            width: wide ? 240 : double.infinity,
            child: FilledButton.icon(
              onPressed: _canSave ? () => unawaited(_save()) : null,
              icon: const Icon(Icons.save_outlined, size: 17),
              label: Text(
                _exporting
                    ? 'Guardando…'
                    : _withShortcut('Guardar copia', 'Ctrl+S'),
              ),
            ),
          );
          final summary = _buildResultSummary(context);
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
                if (wide)
                  Row(
                    children: [
                      Expanded(child: summary),
                      const SizedBox(width: 12),
                      saveButton,
                    ],
                  )
                else ...[
                  Align(alignment: Alignment.centerLeft, child: summary),
                  const SizedBox(height: 8),
                  saveButton,
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  /// What the exported file will actually be. MediaEditRequest already works
  /// the length and pixel size out exactly so they can be shown rather than
  /// left to an ffmpeg expression — until now nothing displayed them, and the
  /// user had to press Guardar to find out what they were getting.
  Widget _buildResultSummary(BuildContext context) {
    final request = _request;
    if (request == null) return const SizedBox.shrink();
    final effective = _effectiveRequest();
    final colors = Theme.of(context).colorScheme;
    if (!effective.hasChanges) {
      return Text(
        'Sin cambios todavía. Ajusta el clip para poder guardar una copia.',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
      );
    }
    if (!effective.hasUsableSelection) {
      return Text(
        'La selección es demasiado corta para exportarla.',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: colors.error),
      );
    }
    final parts = <String>[formatDuration(effective.outputDuration)];
    final size = effective.outputSize;
    if (size != null) parts.add('${size.width}×${size.height}');
    if (effective.isSpeedAdjusted) parts.add('${effective.speed}×');
    if (effective.mute) {
      parts.add('sin audio');
    } else if (effective.isVolumeAdjusted) {
      parts.add('volumen ${(effective.volume * 100).round()}%');
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.movie_creation_outlined, size: 15, color: colors.primary),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            'Resultado: ${parts.join(' · ')}',
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
      ],
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
    required this.touchLayout,
    required this.onRangeChanged,
    required this.onSeekStart,
    required this.onSeek,
    required this.onSeekEnd,
  });

  final int durationMilliseconds;
  final RangeValues range;
  final double positionMilliseconds;
  final bool enabled;
  final bool touchLayout;
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
    final handleBand = widget.touchLayout ? 24.0 : 18.0;
    final grabRadius = widget.touchLayout ? 26.0 : 18.0;
    if (details.localPosition.dy >= handleBand &&
        math.min(startDistance, endDistance) <= grabRadius &&
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
        height: widget.touchLayout ? 54 : 42,
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
                  handleRadius: widget.touchLayout ? 11 : 8,
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
    required this.handleRadius,
    required this.activeColor,
    required this.inactiveColor,
    required this.playheadColor,
  });

  final int durationMilliseconds;
  final RangeValues range;
  final double positionMilliseconds;
  final bool enabled;
  final double handleRadius;
  final Color activeColor;
  final Color inactiveColor;
  final Color playheadColor;

  double _x(double value, double width) {
    final duration = math.max(1, durationMilliseconds);
    return 10 + (value / duration).clamp(0.0, 1.0) * (width - 20);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Derived from the height so the same painter serves the taller touch
    // bar and the compact pointer one without a second set of constants.
    final trackY = size.height * .6;
    final playheadTop = size.height * .16;
    final startX = _x(range.start, size.width);
    final endX = _x(range.end, size.width);
    final playheadX = _x(positionMilliseconds, size.width);
    final opacity = enabled ? 1.0 : .45;

    canvas.drawLine(
      Offset(10, trackY),
      Offset(size.width - 10, trackY),
      Paint()
        ..color = inactiveColor.withValues(alpha: .65 * opacity)
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );
    // The trimmed-away head and tail are dimmed rather than merely left
    // undrawn, so at a glance it is obvious how much of the clip survives.
    canvas.drawLine(
      Offset(startX, trackY),
      Offset(endX, trackY),
      Paint()
        ..color = activeColor.withValues(alpha: opacity)
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round,
    );
    final handlePaint = Paint()..color = activeColor.withValues(alpha: opacity);
    canvas.drawCircle(Offset(startX, trackY), handleRadius, handlePaint);
    canvas.drawCircle(Offset(endX, trackY), handleRadius, handlePaint);

    final playheadPaint = Paint()
      ..color = playheadColor.withValues(alpha: opacity)
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(playheadX, playheadTop),
      Offset(playheadX, trackY + handleRadius),
      playheadPaint,
    );
    canvas.drawCircle(Offset(playheadX, playheadTop), 4, playheadPaint);
  }

  @override
  bool shouldRepaint(covariant _TrimTimelinePainter oldDelegate) =>
      oldDelegate.durationMilliseconds != durationMilliseconds ||
      oldDelegate.range != range ||
      oldDelegate.positionMilliseconds != positionMilliseconds ||
      oldDelegate.enabled != enabled ||
      oldDelegate.handleRadius != handleRadius ||
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

/// Shows where one trim handle sits and moves it to the playhead when
/// pressed. Doubling the readout as the control keeps the row compact while
/// giving touch users the same precision the I/O keys give on desktop.
class _TrimEdgeButton extends StatelessWidget {
  const _TrimEdgeButton({
    required this.label,
    required this.value,
    required this.tooltip,
    required this.height,
    required this.onPressed,
  });

  final String label;
  final String value;
  final String tooltip;
  final double height;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        height: height,
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            minimumSize: Size(0, height),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: enabled
                        ? colors.onSurfaceVariant
                        : colors.onSurfaceVariant.withValues(alpha: .45),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  value,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: enabled
                        ? colors.onSurface
                        : colors.onSurface.withValues(alpha: .45),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
