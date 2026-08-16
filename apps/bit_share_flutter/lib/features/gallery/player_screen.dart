import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../core/media_formatting.dart';
import '../editor/editor_screen.dart';
import 'media_library.dart';

/// Full-screen playback for one item from the gallery grid, and the entry
/// point into the editor for videos and audio.
class MediaPlayerScreen extends StatefulWidget {
  const MediaPlayerScreen({
    required this.item,
    required this.library,
    super.key,
  });

  final MediaItem item;
  final MediaLibrary library;

  @override
  State<MediaPlayerScreen> createState() => _MediaPlayerScreenState();
}

class _MediaPlayerScreenState extends State<MediaPlayerScreen> {
  VideoPlayerController? _controller;
  Future<void>? _initialization;
  String? _imagePath;
  Duration? _scrubPosition;
  Timer? _scrubDebounce;
  bool _resumeAfterScrub = false;

  @override
  void initState() {
    super.initState();
    if (widget.item.kind == MediaKind.image) {
      unawaited(_loadImage());
    } else {
      _initialization = _initializePlayer();
    }
  }

  Future<void> _loadImage() async {
    final path = await widget.library.thumbnailPath(widget.item);
    if (mounted) setState(() => _imagePath = path);
  }

  Future<void> _initializePlayer() async {
    final item = widget.item;
    final controller = item.path != null
        ? VideoPlayerController.file(File(item.path!))
        : VideoPlayerController.contentUri(Uri.parse(item.uri));
    _controller = controller;
    await controller.initialize();
    if (!mounted) return;
    await controller.play();
    setState(() {});
  }

  @override
  void dispose() {
    _scrubDebounce?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 52,
        titleSpacing: 0,
        scrolledUnderElevation: 0,
        title: Text(
          item.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        actions: [
          if (item.isEditable)
            IconButton(
              tooltip: 'Editar',
              visualDensity: VisualDensity.compact,
              onPressed: () => unawaited(_openEditor()),
              icon: const Icon(Icons.content_cut_rounded, size: 19),
            ),
          if (widget.library.canShare)
            IconButton(
              tooltip: 'Compartir',
              visualDensity: VisualDensity.compact,
              onPressed: () => unawaited(_share()),
              icon: const Icon(Icons.share_outlined, size: 19),
            ),
          if (widget.library.canCopyToClipboard && !widget.library.canShare)
            IconButton(
              tooltip: 'Copiar archivo',
              visualDensity: VisualDensity.compact,
              onPressed: () => unawaited(_copyToClipboard()),
              icon: const Icon(Icons.content_copy_outlined, size: 19),
            ),
          if (widget.library.canRevealInFileManager)
            IconButton(
              tooltip: 'Mostrar en carpeta',
              visualDensity: VisualDensity.compact,
              onPressed: () =>
                  unawaited(widget.library.revealInFileManager(item)),
              icon: const Icon(Icons.folder_open_outlined, size: 19),
            ),
          IconButton(
            tooltip: 'Borrar',
            visualDensity: VisualDensity.compact,
            onPressed: () => unawaited(_delete()),
            icon: const Icon(Icons.delete_outline, size: 19),
          ),
        ],
      ),
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.space): _togglePlayback,
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              _seekRelative(const Duration(seconds: -10)),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              _seekRelative(const Duration(seconds: 10)),
        },
        child: Focus(
          autofocus: true,
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(
                    child: _buildBody(context, item, constraints.maxHeight),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    MediaItem item,
    double availableHeight,
  ) {
    if (item.kind == MediaKind.image) {
      final path = _imagePath;
      if (path == null) return const CircularProgressIndicator();
      return InteractiveViewer(child: Image.file(File(path)));
    }
    return FutureBuilder<void>(
      future: _initialization,
      builder: (context, snapshot) {
        final controller = _controller;
        if (snapshot.connectionState != ConnectionState.done ||
            controller == null) {
          return const CircularProgressIndicator();
        }
        if (snapshot.hasError) {
          return Text(
            'No se pudo reproducir este archivo.',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (item.kind == MediaKind.video)
                _buildVideoPreview(context, controller, availableHeight)
              else
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Icon(
                    Icons.audiotrack_rounded,
                    size: 96,
                    color: Colors.white38,
                  ),
                ),
              const SizedBox(height: 12),
              _buildPlaybackControls(context, controller),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPlaybackControls(
    BuildContext context,
    VideoPlayerController controller,
  ) {
    final colors = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: colors.outlineVariant.withValues(alpha: .55),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final duration = value.duration;
              final maxMilliseconds = math.max(1, duration.inMilliseconds);
              final rawPosition = _scrubPosition ?? value.position;
              final position = Duration(
                milliseconds: rawPosition.inMilliseconds.clamp(
                  0,
                  maxMilliseconds,
                ),
              );
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        formatDuration(position),
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const Spacer(),
                      Text(
                        formatDuration(duration),
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                  SizedBox(
                    height: 34,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 4,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14,
                        ),
                      ),
                      child: Slider(
                        key: const Key('player-time-slider'),
                        value: position.inMilliseconds.toDouble(),
                        min: 0,
                        max: maxMilliseconds.toDouble(),
                        onChangeStart: (milliseconds) {
                          _resumeAfterScrub = value.isPlaying;
                          if (value.isPlaying) unawaited(controller.pause());
                          setState(
                            () => _scrubPosition = Duration(
                              milliseconds: milliseconds.round(),
                            ),
                          );
                        },
                        onChanged: (milliseconds) =>
                            _updateScrub(controller, milliseconds),
                        onChangeEnd: (milliseconds) =>
                            unawaited(_finishScrub(controller, milliseconds)),
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: 'Retroceder 10 segundos',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.replay_10_rounded, size: 22),
                        onPressed: () =>
                            _seekRelative(const Duration(seconds: -10)),
                      ),
                      const SizedBox(width: 10),
                      IconButton.filled(
                        tooltip: value.isPlaying ? 'Pausar' : 'Reproducir',
                        iconSize: 24,
                        visualDensity: VisualDensity.compact,
                        onPressed: _togglePlayback,
                        icon: Icon(
                          value.isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton(
                        tooltip: 'Avanzar 10 segundos',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.forward_10_rounded, size: 22),
                        onPressed: () =>
                            _seekRelative(const Duration(seconds: 10)),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _updateScrub(VideoPlayerController controller, double milliseconds) {
    final position = Duration(milliseconds: milliseconds.round());
    setState(() => _scrubPosition = position);
    _scrubDebounce?.cancel();
    _scrubDebounce = Timer(
      const Duration(milliseconds: 35),
      () => unawaited(controller.seekTo(position)),
    );
  }

  Future<void> _finishScrub(
    VideoPlayerController controller,
    double milliseconds,
  ) async {
    _scrubDebounce?.cancel();
    final position = Duration(milliseconds: milliseconds.round());
    await controller.seekTo(position);
    if (_resumeAfterScrub) await controller.play();
    if (mounted) setState(() => _scrubPosition = null);
  }

  void _togglePlayback() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    unawaited(
      controller.value.isPlaying ? controller.pause() : controller.play(),
    );
  }

  void _seekRelative(Duration delta) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final duration = controller.value.duration;
    final targetMilliseconds = (controller.value.position + delta)
        .inMilliseconds
        .clamp(0, duration.inMilliseconds);
    unawaited(controller.seekTo(Duration(milliseconds: targetMilliseconds)));
  }

  Widget _buildVideoPreview(
    BuildContext context,
    VideoPlayerController controller,
    double availableHeight,
  ) {
    final rawAspectRatio = controller.value.aspectRatio;
    final aspectRatio =
        rawAspectRatio.isFinite && rawAspectRatio >= .2 && rawAspectRatio <= 5
        ? rawAspectRatio
        : 16 / 9;
    final maxHeight = math.min(availableHeight * .58, 480.0);
    final maxWidth = MediaQuery.sizeOf(context).width - 32;
    final width = math.min(maxWidth, maxHeight * aspectRatio);
    return SizedBox(
      width: width,
      height: width / aspectRatio,
      child: ColoredBox(
        color: Colors.black,
        // Keep the Windows GPU texture directly in the compositor so native
        // frame notifications are not delayed by raster caching.
        child: VideoPlayer(controller),
      ),
    );
  }

  Future<void> _openEditor() async {
    await _controller?.pause();
    if (!mounted) return;
    final edited = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            EditorScreen(item: widget.item, library: widget.library),
      ),
    );
    if (edited == true && mounted) Navigator.of(context).pop();
  }

  Future<void> _share() async {
    try {
      final shared = await widget.library.share(widget.item);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            shared
                ? widget.library.canCopyToClipboard
                      ? 'Archivo listo: pégalo en WhatsApp, Telegram o la app que quieras.'
                      : 'Elige dónde compartir el archivo.'
                : 'No se pudo compartir el archivo.',
          ),
        ),
      );
    } on MediaLibraryException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _copyToClipboard() async {
    try {
      await widget.library.copyToClipboard(widget.item);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Archivo copiado al portapapeles.')),
        );
      }
    } on MediaLibraryException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Borrar elemento'),
        content: Text('¿Borrar "${widget.item.name}" de Bit-Share?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.library.delete([widget.item]);
      if (mounted) Navigator.of(context).pop();
    } on MediaLibraryException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }
}
