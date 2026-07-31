import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/web_url.dart';
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
            constraints: const BoxConstraints(maxWidth: 940),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(32, 32, 32, 24),
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
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(14),
                        child: Icon(
                          Icons.download_rounded,
                          size: 28,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Bit-Share',
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          Text(
                            'Descarga contenido compatible desde un enlace.',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _downloading
                          ? null
                          : () =>
                                unawaited(widget.backend.openOutputDirectory()),
                      icon: const Icon(Icons.folder_open_outlined),
                      label: const Text('Abrir descargas'),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Pega un enlace',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: TextField(
                                key: const Key('windows-url-field'),
                                controller: _urlController,
                                enabled: !_downloading,
                                keyboardType: TextInputType.url,
                                textInputAction: TextInputAction.done,
                                autocorrect: false,
                                decoration: InputDecoration(
                                  hintText: 'https://...',
                                  prefixIcon: const Icon(Icons.link),
                                  suffixIcon: _urlController.text.isEmpty
                                      ? null
                                      : IconButton(
                                          tooltip: 'Limpiar',
                                          onPressed: _reset,
                                          icon: const Icon(Icons.close),
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
                            const SizedBox(width: 12),
                            OutlinedButton.icon(
                              key: const Key('windows-paste-button'),
                              onPressed: _downloading ? null : _paste,
                              icon: const Icon(Icons.content_paste_rounded),
                              label: const Text('Pegar'),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(116, 56),
                              ),
                            ),
                            const SizedBox(width: 12),
                            FilledButton.icon(
                              key: const Key('windows-inspect-button'),
                              onPressed: _inspecting || _downloading
                                  ? null
                                  : _inspect,
                              icon: _inspecting
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.search_rounded),
                              label: Text(
                                _inspecting ? 'Analizando…' : 'Analizar',
                              ),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(140, 56),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
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
                  ),
                ],
                if (inspection != null) ...[
                  const SizedBox(height: 16),
                  _buildOptions(context, inspection),
                ],
                if (_downloading || _completedPath != null) ...[
                  const SizedBox(height: 16),
                  _buildTaskStatus(context),
                ],
                const SizedBox(height: 24),
                Text(
                  'powered by BitStation',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'PressStart2P',
                    fontSize: 8,
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
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              inspection.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              inspection.providerName,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            SegmentedButton<WindowsDownloadMode>(
              segments: const [
                ButtonSegment(
                  value: WindowsDownloadMode.video,
                  icon: Icon(Icons.movie_outlined),
                  label: Text('Vídeo'),
                ),
                ButtonSegment(
                  value: WindowsDownloadMode.audio,
                  icon: Icon(Icons.graphic_eq_rounded),
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
              const SizedBox(height: 20),
              Text(
                'Resolución disponible',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 250),
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
                        key: Key('windows-resolution-${resolution.height}'),
                        selected: selected,
                        leading: Icon(
                          selected
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                        ),
                        title: Text(
                          resolution.label,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        trailing: resolution.estimatedBytes == null
                            ? null
                            : Text(_formatBytes(resolution.estimatedBytes!)),
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
            const SizedBox(height: 16),
            Row(
              children: [
                const Icon(Icons.save_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    estimatedBytes == null
                        ? 'Tamaño final por determinar'
                        : 'Tamaño estimado: ${_formatBytes(estimatedBytes)}',
                  ),
                ),
                if (inspection.availableBytes > 0)
                  Text(
                    '${_formatBytes(inspection.availableBytes)} libres',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            if (!fitsStorage) ...[
              const SizedBox(height: 10),
              Text(
                'No hay espacio suficiente para descargar y procesar '
                'esta opción.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 18),
            FilledButton.icon(
              key: const Key('windows-download-button'),
              onPressed: _downloading || !fitsStorage ? null : _download,
              icon: const Icon(Icons.download_rounded),
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
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_downloading) ...[
              Text(
                _status == 'processing'
                    ? 'Procesando archivo…'
                    : 'Descargando… ${_progress.toStringAsFixed(0)}%',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: _progress <= 0 ? null : _progress / 100,
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: _cancel,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Cancelar'),
              ),
            ] else if (completedPath != null) ...[
              Row(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Descarga completada',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SelectableText(
                completedPath,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: widget.backend.openOutputDirectory,
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('Mostrar en Descargas'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _paste() async {
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
      if (mounted) setState(() => _completedPath = result.filePath);
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

  Future<void> _openLogin() async {
    final url = extractWebUrl(_urlController.text);
    if (url == null) return;
    try {
      await widget.backend.openLoginPage(url, _browserSession);
      if (mounted) {
        setState(() {
          _error =
              'Inicia sesión en ${_browserSession.label}, cierra el navegador '
              'si está bloqueando sus cookies y pulsa “Reintentar con mi sesión”.';
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
  });

  final String message;
  final bool authenticationRequired;
  final WindowsBrowserSession browserSession;
  final ValueChanged<WindowsBrowserSession?> onBrowserChanged;
  final VoidCallback onOpenLogin;
  final VoidCallback onRetryAuthenticated;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(
        context,
      ).colorScheme.errorContainer.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  authenticationRequired
                      ? Icons.lock_outline
                      : Icons.error_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(message)),
              ],
            ),
            if (authenticationRequired) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<WindowsBrowserSession>(
                      initialValue: browserSession,
                      decoration: const InputDecoration(
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
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: onOpenLogin,
                    icon: const Icon(Icons.open_in_browser),
                    label: const Text('Abrir e iniciar sesión'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(190, 56),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    key: const Key('windows-auth-retry-button'),
                    onPressed: onRetryAuthenticated,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reintentar con mi sesión'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(210, 56),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Bit-Share no recibe tu contraseña. La sesión se consulta '
                'localmente y solo después de tu autorización explícita.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
