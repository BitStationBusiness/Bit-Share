import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

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
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Scaffold(
      appBar: AppBar(
        title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (item.isEditable)
            IconButton(
              tooltip: 'Editar',
              onPressed: () => unawaited(_openEditor()),
              icon: const Icon(Icons.content_cut_rounded),
            ),
          if (widget.library.canShare)
            IconButton(
              tooltip: 'Compartir',
              onPressed: () => unawaited(_share()),
              icon: const Icon(Icons.share_outlined),
            ),
          if (widget.library.canCopyToClipboard && !widget.library.canShare)
            IconButton(
              tooltip: 'Copiar archivo',
              onPressed: () => unawaited(_copyToClipboard()),
              icon: const Icon(Icons.content_copy_outlined),
            ),
          if (widget.library.canRevealInFileManager)
            IconButton(
              tooltip: 'Mostrar en carpeta',
              onPressed: () =>
                  unawaited(widget.library.revealInFileManager(item)),
              icon: const Icon(Icons.folder_open_outlined),
            ),
          IconButton(
            tooltip: 'Borrar',
            onPressed: () => unawaited(_delete()),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Center(child: _buildBody(context, item)),
    );
  }

  Widget _buildBody(BuildContext context, MediaItem item) {
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
                AspectRatio(
                  aspectRatio: controller.value.aspectRatio == 0
                      ? 16 / 9
                      : controller.value.aspectRatio,
                  child: VideoPlayer(controller),
                )
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
              VideoProgressIndicator(
                controller,
                allowScrubbing: true,
                padding: const EdgeInsets.symmetric(horizontal: 20),
              ),
              const SizedBox(height: 4),
              ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: controller,
                builder: (context, value, _) => IconButton(
                  iconSize: 44,
                  icon: Icon(
                    value.isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                  ),
                  onPressed: () =>
                      value.isPlaying ? controller.pause() : controller.play(),
                ),
              ),
            ],
          ),
        );
      },
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
