import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/media_formatting.dart';
import '../update/update_gate.dart';
import 'media_library.dart';
import 'player_screen.dart';

/// What opens when Bit-Share is launched from its own icon on Android, and
/// what the Windows download screen's "Galería" button leads to. Shows only
/// the media Bit-Share itself downloaded — never a general device gallery.
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({MediaLibrary? library, super.key}) : _library = library;

  final MediaLibrary? _library;

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  late final MediaLibrary _library = widget._library ?? createMediaLibrary();
  final Set<MediaItem> _selected = {};
  final Map<String, Future<String?>> _thumbnails = {};
  late Future<MediaLibrarySnapshot> _future;

  @override
  void initState() {
    super.initState();
    _future = _library.load();
  }

  void _refresh() {
    setState(() {
      _thumbnails.clear();
      _future = _library.load();
    });
  }

  Future<String?> _thumbnailFor(MediaItem item) {
    return _thumbnails.putIfAbsent(item.id, () => _library.thumbnailPath(item));
  }

  void _toggleSelection(MediaItem item) {
    setState(() {
      if (!_selected.remove(item)) _selected.add(item);
    });
  }

  Future<void> _open(MediaItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MediaPlayerScreen(item: item, library: _library),
      ),
    );
    _refresh();
  }

  Future<void> _share(MediaItem item) async {
    final shared = await _library.share(item);
    if (!shared && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo compartir el archivo.')),
      );
    }
  }

  Future<void> _deleteSelected() async {
    final items = List<MediaItem>.from(_selected);
    if (items.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Borrar elementos'),
        content: Text(
          '¿Borrar ${items.length} elemento(s) de Bit-Share? '
          'Esta acción no se puede deshacer.',
        ),
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
    if (confirmed != true) return;
    try {
      await _library.delete(items);
    } on MediaLibraryException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
    if (!mounted) return;
    setState(_selected.clear);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final selecting = _selected.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(selecting ? '${_selected.length} seleccionado(s)' : 'Bit-Share'),
        actions: selecting
            ? [
                if (_library.canShare)
                  IconButton(
                    tooltip: 'Compartir',
                    onPressed: _selected.length == 1
                        ? () => unawaited(_share(_selected.first))
                        : null,
                    icon: const Icon(Icons.share_outlined),
                  ),
                IconButton(
                  tooltip: 'Borrar',
                  onPressed: () => unawaited(_deleteSelected()),
                  icon: const Icon(Icons.delete_outline),
                ),
                IconButton(
                  tooltip: 'Cancelar selección',
                  onPressed: () => setState(_selected.clear),
                  icon: const Icon(Icons.close),
                ),
              ]
            : [
                IconButton(
                  tooltip: 'Actualizar la lista',
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh_rounded),
                ),
                IconButton(
                  key: const Key('gallery-check-updates-button'),
                  tooltip: 'Buscar actualizaciones de Bit-Share',
                  onPressed: () =>
                      unawaited(checkForUpdatesInteractively(context)),
                  icon: const Icon(Icons.system_update_alt_rounded),
                ),
              ],
      ),
      body: FutureBuilder<MediaLibrarySnapshot>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            final error = snapshot.error;
            return _MessageState(
              icon: Icons.error_outline,
              message: error is MediaLibraryException
                  ? error.message
                  : 'No se pudo leer la galería de Bit-Share.',
              onRetry: _refresh,
            );
          }
          final data = snapshot.data ?? MediaLibrarySnapshot.empty;
          if (data.items.isEmpty) {
            return _MessageState(
              icon: Icons.video_library_outlined,
              message:
                  'Aún no hay descargas de Bit-Share.\n'
                  'Comparte un enlace con la app para verlas aquí.',
              onRetry: _refresh,
            );
          }
          return RefreshIndicator(
            onRefresh: () async {
              _refresh();
              await _future;
            },
            child: GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 170,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 0.78,
              ),
              itemCount: data.items.length,
              itemBuilder: (context, index) {
                final item = data.items[index];
                return _MediaTile(
                  item: item,
                  thumbnail: _thumbnailFor(item),
                  selected: _selected.contains(item),
                  selecting: selecting,
                  onTap: () =>
                      selecting ? _toggleSelection(item) : unawaited(_open(item)),
                  onLongPress: () => _toggleSelection(item),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _MediaTile extends StatelessWidget {
  const _MediaTile({
    required this.item,
    required this.thumbnail,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  final MediaItem item;
  final Future<String?> thumbnail;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Material(
        color: const Color(0xFF1B1724),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Stack(
            fit: StackFit.expand,
            children: [
              FutureBuilder<String?>(
                future: thumbnail,
                builder: (context, snapshot) {
                  final path = snapshot.data;
                  if (path == null) return _FallbackIcon(kind: item.kind);
                  return Image.file(
                    File(path),
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        _FallbackIcon(kind: item.kind),
                  );
                },
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.75),
                    ],
                    stops: const [0.6, 1],
                  ),
                ),
              ),
              Positioned(
                left: 6,
                right: 6,
                bottom: 6,
                child: Row(
                  children: [
                    Icon(_kindIcon(item.kind), size: 13, color: Colors.white),
                    const SizedBox(width: 4),
                    if (item.duration != null)
                      Text(
                        formatDuration(item.duration!),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    const Spacer(),
                    Text(
                      formatBytes(item.sizeBytes),
                      style: const TextStyle(fontSize: 10.5, color: Colors.white70),
                    ),
                  ],
                ),
              ),
              if (selecting)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Icon(
                    selected ? Icons.check_circle : Icons.circle_outlined,
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.white70,
                  ),
                ),
              if (selected)
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.25),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _kindIcon(MediaKind kind) => switch (kind) {
    MediaKind.video => Icons.play_circle_outline,
    MediaKind.audio => Icons.audiotrack_rounded,
    MediaKind.image => Icons.image_outlined,
  };
}

class _FallbackIcon extends StatelessWidget {
  const _FallbackIcon({required this.kind});

  final MediaKind kind;

  @override
  Widget build(BuildContext context) {
    final icon = switch (kind) {
      MediaKind.video => Icons.movie_outlined,
      MediaKind.audio => Icons.music_note_rounded,
      MediaKind.image => Icons.image_outlined,
    };
    return ColoredBox(
      color: const Color(0xFF241E30),
      child: Center(child: Icon(icon, size: 34, color: Colors.white38)),
    );
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.message,
    required this.onRetry,
  });

  final IconData icon;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Actualizar'),
            ),
          ],
        ),
      ),
    );
  }
}
