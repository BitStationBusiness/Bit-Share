import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/web_url.dart';
import '../editor/editor_screen.dart';
import '../gallery/gallery_screen.dart';
import '../gallery/media_library.dart';
import 'windows_download_backend.dart';

class WindowsDownloadScreen extends StatefulWidget {
  WindowsDownloadScreen({WindowsDownloadBackend? backend, super.key})
    : backend = backend ?? createWindowsDownloadBackend();

  final WindowsDownloadBackend backend;

  @override
  State<WindowsDownloadScreen> createState() => _WindowsDownloadScreenState();
}

class _WindowsDownloadScreenState extends State<WindowsDownloadScreen> {
  final TextEditingController _urlController = TextEditingController();
  WindowsMediaInspection? _inspection;
  WindowsDownloadMode _mode = WindowsDownloadMode.video;
  WindowsBrowserSession _browserSession = WindowsBrowserSession.edge;
  WindowsBrowserSession? _activeBrowserSession;
  int? _selectedHeight;
  bool _inspecting = false;
  bool _downloading = false;
  bool _authenticationRequired = false;
  double _progress = 0;
  String? _status;
  String? _error;
  String? _completedPath;
  int _completedFileCount = 1;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inspection = _inspection;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              children: [
                Row(
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF39BDF8), Color(0xFF9B58F5)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(9),
                        child: Icon(
                          Icons.download_rounded,
                          size: 19,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Bit-Share',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            'Descarga contenido compatible desde un enlace.',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _HeaderAction(
                      key: const Key('windows-header-gallery-button'),
                      icon: Icons.video_library_outlined,
                      tooltip: 'Galería: ver y editar lo descargado',
                      onPressed: () => unawaited(_openGallery()),
                    ),
                    _HeaderAction(
                      icon: Icons.folder_open_outlined,
                      tooltip: 'Abrir la carpeta de descargas',
                      onPressed: _downloading
                          ? null
                          : () =>
                                unawaited(widget.backend.openOutputDirectory()),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Pega un enlace con Ctrl+V',
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 10),
                        CallbackShortcuts(
                          bindings: {
                            const SingleActivator(
                              LogicalKeyboardKey.keyV,
                              control: true,
                            ): () =>
                                unawaited(_pasteFromShortcut()),
                          },
                          child: TextField(
                            key: const Key('windows-url-field'),
                            controller: _urlController,
                            enabled: !_downloading,
                            keyboardType: TextInputType.url,
                            textInputAction: TextInputAction.done,
                            autocorrect: false,
                            style: const TextStyle(fontSize: 13.5),
                            decoration: InputDecoration(
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              hintText: 'Pulsa Ctrl+V para pegar un enlace',
                              prefixIcon: const Icon(Icons.link, size: 18),
                              suffixIcon: _urlController.text.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: 'Limpiar',
                                      onPressed: _reset,
                                      icon: const Icon(Icons.close, size: 16),
                                    ),
                              border: const OutlineInputBorder(),
                            ),
                            onChanged: (_) => setState(() {
                              _inspection = null;
                              _error = null;
                              _authenticationRequired = false;
                              _activeBrowserSession = null;
                              _completedPath = null;
                            }),
                            onSubmitted: (_) => unawaited(_inspect()),
                          ),
                        ),
                        if (_inspecting) ...[
                          const SizedBox(height: 10),
                          const ClipRRect(
                            borderRadius: BorderRadius.all(Radius.circular(4)),
                            child: LinearProgressIndicator(minHeight: 4),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  _ErrorPanel(
                    message: _error!,
                    authenticationRequired: _authenticationRequired,
                    browserSession: _browserSession,
                    onBrowserChanged: (value) {
                      if (value != null) {
                        setState(() => _browserSession = value);
                      }
                    },
                    onOpenLogin: () => unawaited(_openLogin()),
                    onRetryAuthenticated: () =>
                        unawaited(_inspect(browserSession: _browserSession)),
                    onRetry: () => unawaited(_retry()),
                  ),
                ],
                if (inspection != null) ...[
                  const SizedBox(height: 12),
                  _buildOptions(context, inspection),
                ],
                if (_downloading || _completedPath != null) ...[
                  const SizedBox(height: 12),
                  _buildTaskStatus(context),
                ],
                const SizedBox(height: 14),
                Text(
                  'powered by BitStation',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'PressStart2P',
                    fontSize: 7,
                    height: 1.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOptions(
    BuildContext context,
    WindowsMediaInspection inspection,
  ) {
    final selectedResolution = inspection.resolutions
        .where((item) => item.height == _selectedHeight)
        .firstOrNull;
    final estimatedBytes = _mode == WindowsDownloadMode.audio
        ? inspection.audioEstimatedBytes
        : selectedResolution?.estimatedBytes;
    final requiredBytes = estimatedBytes == null
        ? null
        : estimatedBytes * (_mode == WindowsDownloadMode.video ? 2 : 1) +
              64 * 1024 * 1024;
    final fitsStorage =
        requiredBytes == null ||
        inspection.availableBytes <= 0 ||
        inspection.availableBytes >= requiredBytes;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              inspection.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 3),
            Text(
              inspection.providerName,
              style: TextStyle(
                fontSize: 12.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            SegmentedButton<WindowsDownloadMode>(
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              segments: const [
                ButtonSegment(
                  value: WindowsDownloadMode.video,
                  icon: Icon(Icons.movie_outlined, size: 16),
                  label: Text('Vídeo'),
                ),
                ButtonSegment(
                  value: WindowsDownloadMode.audio,
                  icon: Icon(Icons.graphic_eq_rounded, size: 16),
                  label: Text('Solo audio'),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (selection) {
                final mode = selection.first;
                if (mode == WindowsDownloadMode.audio &&
                    !inspection.audioAvailable) {
                  return;
                }
                if (mode == WindowsDownloadMode.video &&
                    inspection.resolutions.isEmpty) {
                  return;
                }
                setState(() => _mode = mode);
              },
            ),
            if (_mode == WindowsDownloadMode.video) ...[
              const SizedBox(height: 14),
              Text(
                'Resolución disponible',
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: inspection.resolutions.length,
                    separatorBuilder: (_, _) => Divider(
                      height: 1,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    itemBuilder: (context, index) {
                      final resolution = inspection.resolutions[index];
                      final selected = resolution.height == _selectedHeight;
                      return ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        key: Key('windows-resolution-${resolution.height}'),
                        selected: selected,
                        leading: Icon(
                          selected
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                          size: 18,
                        ),
                        title: Text(
                          resolution.label,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        trailing: resolution.estimatedBytes == null
                            ? null
                            : Text(
                                _formatBytes(resolution.estimatedBytes!),
                                style: const TextStyle(fontSize: 12.5),
                              ),
                        onTap: _downloading
                            ? null
                            : () => setState(
                                () => _selectedHeight = resolution.height,
                              ),
                      );
                    },
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  Icons.save_outlined,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    estimatedBytes == null
                        ? 'Tamaño final por determinar'
                        : 'Tamaño estimado: ${_formatBytes(estimatedBytes)}',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                if (inspection.availableBytes > 0)
                  Text(
                    '${_formatBytes(inspection.availableBytes)} libres',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            if (!fitsStorage) ...[
              const SizedBox(height: 8),
              Text(
                'No hay espacio suficiente para descargar y procesar '
                'esta opción.',
                style: TextStyle(
                  fontSize: 12.5,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 14),
            FilledButton.icon(
              key: const Key('windows-download-button'),
              onPressed: _downloading || !fitsStorage ? null : _download,
              icon: const Icon(Icons.download_rounded, size: 17),
              label: Text(
                _mode == WindowsDownloadMode.audio
                    ? 'Descargar audio'
                    : 'Descargar vídeo',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskStatus(BuildContext context) {
    final completedPath = _completedPath;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_downloading) ...[
              Text(
                switch (_status) {
                  'processing' => 'Procesando archivo…',
                  'retrying' => 'Conexión inestable, reintentando…',
                  _ => 'Descargando… ${_progress.toStringAsFixed(0)}%',
                },
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _progress <= 0 ? null : _progress / 100,
                  minHeight: 5,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _cancel,
                icon: const Icon(Icons.stop_circle_outlined, size: 16),
                label: const Text('Cancelar'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
              ),
            ] else if (completedPath != null) ...[
              Row(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 20,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Descarga completada',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              SelectableText(
                completedPath,
                style: TextStyle(
                  fontSize: 12.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (_completedFileCount > 1) ...[
                const SizedBox(height: 4),
                Text(
                  'Y ${_completedFileCount - 1} archivo(s) más en la misma '
                  'carpeta.',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              _buildCompletedActions(context),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCompletedActions(BuildContext context) {
    final galleryButton = FilledButton.icon(
      key: const Key('windows-gallery-button'),
      onPressed: () => unawaited(_openGallery()),
      icon: const Icon(Icons.video_library_outlined, size: 17),
      label: const Text('Galería'),
    );
    final editButton = OutlinedButton.icon(
      key: const Key('windows-edit-result-button'),
      onPressed: () => unawaited(_editCompletedFile()),
      icon: const Icon(Icons.content_cut_rounded, size: 17),
      label: const Text('Editar'),
    );
    final shareButton = OutlinedButton.icon(
      key: const Key('windows-copy-file-button'),
      onPressed: () => unawaited(_shareCompletedFile()),
      icon: const Icon(Icons.share_outlined, size: 17),
      label: const Text('Compartir'),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 600) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              galleryButton,
              const SizedBox(height: 8),
              editButton,
              const SizedBox(height: 8),
              shareButton,
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: galleryButton),
            const SizedBox(width: 10),
            Expanded(child: editButton),
            const SizedBox(width: 10),
            Expanded(child: shareButton),
          ],
        );
      },
    );
  }

  Future<void> _openGallery() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const GalleryScreen()));
  }

  Future<void> _pasteFromShortcut() async {
    if (_inspecting || _downloading) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final value = data?.text?.trim();
    if (value == null || value.isEmpty) {
      setState(() => _error = 'El portapapeles no contiene un enlace.');
      return;
    }
    _urlController.text = value;
    _urlController.selection = TextSelection.collapsed(offset: value.length);
    await _inspect();
  }

  Future<void> _inspect({WindowsBrowserSession? browserSession}) async {
    final url = extractWebUrl(_urlController.text);
    if (url == null) {
      setState(() {
        _error = 'Pega un enlace web válido.';
        _authenticationRequired = false;
      });
      return;
    }
    setState(() {
      _inspecting = true;
      _error = null;
      _authenticationRequired = false;
      _activeBrowserSession = null;
      _inspection = null;
      _completedPath = null;
    });
    try {
      final inspection = await widget.backend.inspect(
        url,
        browserSession: browserSession,
      );
      if (!mounted) return;
      final preferred = inspection.resolutions
          .where((item) => item.height <= 1080)
          .firstOrNull;
      setState(() {
        _inspection = inspection;
        _activeBrowserSession = browserSession;
        _selectedHeight =
            preferred?.height ?? inspection.resolutions.firstOrNull?.height;
        _mode = inspection.resolutions.isNotEmpty
            ? WindowsDownloadMode.video
            : WindowsDownloadMode.audio;
      });
    } on WindowsDownloadException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _authenticationRequired = error.authenticationRequired;
      });
    } on Object {
      if (!mounted) return;
      setState(() => _error = 'No se pudo analizar este enlace.');
    } finally {
      if (mounted) setState(() => _inspecting = false);
    }
  }

  Future<void> _download() async {
    final inspection = _inspection;
    final url = extractWebUrl(_urlController.text);
    if (inspection == null || url == null) return;
    final selected = inspection.resolutions
        .where((item) => item.height == _selectedHeight)
        .firstOrNull;
    final estimate = _mode == WindowsDownloadMode.audio
        ? inspection.audioEstimatedBytes
        : selected?.estimatedBytes;
    setState(() {
      _downloading = true;
      _error = null;
      _authenticationRequired = false;
      _completedPath = null;
      _progress = 0;
      _status = 'downloading';
    });
    try {
      final result = await widget.backend.download(
        url,
        mode: _mode,
        height: _mode == WindowsDownloadMode.video ? _selectedHeight : null,
        estimatedBytes: estimate,
        browserSession: _activeBrowserSession,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _progress = progress.percent;
            _status = progress.stage;
          });
        },
      );
      if (!mounted) return;
      _urlController.clear();
      setState(() {
        _completedPath = result.filePath;
        _completedFileCount = result.fileCount;
        _inspection = null;
        _selectedHeight = null;
        _activeBrowserSession = null;
      });
    } on WindowsDownloadException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _authenticationRequired = error.authenticationRequired;
      });
    } on Object {
      if (mounted) {
        setState(() => _error = 'No se pudo completar la descarga.');
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  /// A network hiccup mid-download or mid-inspect used to strand the user
  /// with only the paste field and no way back except retyping the link —
  /// this replays whichever step failed, reusing what's already known about
  /// the link instead of throwing it away.
  Future<void> _retry() async {
    if (_inspection != null) {
      await _download();
    } else {
      await _inspect(browserSession: _activeBrowserSession);
    }
  }

  Future<void> _copyCompletedFile() async {
    final path = _completedPath;
    if (path == null || path.isEmpty) return;
    try {
      await widget.backend.copyFileToClipboard(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Archivo copiado al portapapeles.')),
      );
    } on WindowsDownloadException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _shareCompletedFile() async {
    await _copyCompletedFile();
    if (!mounted || _completedPath == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Archivo listo: pégalo en WhatsApp, Telegram o la app que quieras.',
        ),
      ),
    );
  }

  Future<void> _editCompletedFile() async {
    final path = _completedPath;
    if (path == null || path.isEmpty) return;
    final fileName = path.split(RegExp(r'[\\/]')).last;
    final item = MediaItem(
      id: path,
      uri: path,
      path: path,
      name: fileName,
      mimeType: '',
      kind: MediaKind.kindForExtension(fileName),
      sizeBytes: 0,
    );
    if (!item.isEditable) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EditorScreen(item: item, library: createMediaLibrary()),
      ),
    );
  }

  Future<void> _openLogin() async {
    final url = extractWebUrl(_urlController.text);
    if (url == null) return;
    try {
      await widget.backend.openLoginPage(url, _browserSession);
      if (mounted) {
        setState(() {
          _error =
              'Bit-Share abrió ${_browserSession.label} con una sesión propia. '
              'Inicia sesión ahí y pulsa “Reintentar con mi sesión”. Tu '
              'navegador habitual no se toca y no hace falta cerrarlo.';
        });
      }
    } on WindowsDownloadException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _cancel() async {
    await widget.backend.cancel();
    if (!mounted) return;
    setState(() {
      _downloading = false;
      _progress = 0;
      _status = null;
      _error = 'Descarga cancelada.';
    });
  }

  void _reset() {
    _urlController.clear();
    setState(() {
      _inspection = null;
      _selectedHeight = null;
      _authenticationRequired = false;
      _activeBrowserSession = null;
      _completedPath = null;
      _error = null;
    });
  }

  String _formatBytes(int bytes) {
    const gib = 1024 * 1024 * 1024;
    const mib = 1024 * 1024;
    if (bytes >= gib) return '${(bytes / gib).toStringAsFixed(1)} GB';
    if (bytes >= mib) return '${(bytes / mib).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({
    required this.message,
    required this.authenticationRequired,
    required this.browserSession,
    required this.onBrowserChanged,
    required this.onOpenLogin,
    required this.onRetryAuthenticated,
    required this.onRetry,
  });

  final String message;
  final bool authenticationRequired;
  final WindowsBrowserSession browserSession;
  final ValueChanged<WindowsBrowserSession?> onBrowserChanged;
  final VoidCallback onOpenLogin;
  final VoidCallback onRetryAuthenticated;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(
        context,
      ).colorScheme.errorContainer.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  authenticationRequired
                      ? Icons.lock_outline
                      : Icons.error_outline,
                  size: 19,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(message, style: const TextStyle(fontSize: 13)),
                ),
              ],
            ),
            if (authenticationRequired) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<WindowsBrowserSession>(
                initialValue: browserSession,
                isDense: true,
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  labelText: 'Navegador donde iniciarás sesión',
                  border: OutlineInputBorder(),
                ),
                items: WindowsBrowserSession.values
                    .map(
                      (item) => DropdownMenuItem(
                        value: item,
                        child: Text(item.label),
                      ),
                    )
                    .toList(growable: false),
                onChanged: onBrowserChanged,
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: onOpenLogin,
                    icon: const Icon(Icons.open_in_browser, size: 16),
                    label: const Text('Abrir e iniciar sesión'),
                  ),
                  FilledButton.icon(
                    key: const Key('windows-auth-retry-button'),
                    onPressed: onRetryAuthenticated,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Reintentar con mi sesión'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Bit-Share no recibe tu contraseña. La sesión se consulta '
                'localmente y solo después de tu autorización explícita.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(fontSize: 11.5),
              ),
            ] else ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('windows-retry-button'),
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Reintentar'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}


/// Icon-only header action. The content column is capped at 520px, which
/// leaves roughly 174px beside the title and subtitle — not enough for two
/// text labels, so a "shrink to icons when narrow" variant would only ever
/// render its narrow branch. Two matching icons also read better as peer
/// actions than one icon and one labelled button.
class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 19),
    );
  }
}
