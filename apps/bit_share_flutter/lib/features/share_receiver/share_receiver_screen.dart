import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/web_url.dart' as web_url;
import '../../domain/entities/share_payload.dart';
import '../../platform/bitshare_channel.dart';
import '../../platform/bitshare_events.dart';
import 'provider_login.dart';

String? extractWebUrl(String? sharedText) {
  return web_url.extractWebUrl(sharedText);
}

class ShareReceiverScreen extends StatefulWidget {
  const ShareReceiverScreen({super.key});

  @override
  State<ShareReceiverScreen> createState() => _ShareReceiverScreenState();
}

class _ShareReceiverScreenState extends State<ShareReceiverScreen> {
  final BitShareChannel _channel = BitShareChannel();
  StreamSubscription<BitShareEvent>? _subscription;
  SharePayload? _payload;
  Object? _error;
  bool _loading = true;
  bool _inspecting = false;
  bool _startingDownload = false;
  MediaInspection? _inspection;
  DownloadMode _mode = DownloadMode.video;
  int? _selectedHeight;
  String? _inspectionError;
  String? _taskId;
  double _progress = 0;
  String? _stage;
  String? _taskError;
  TaskCompletedEvent? _completedTask;
  bool _donationDialogVisible = false;
  bool _loggingIn = false;
  String? _resolvedUrl;
  String? _resolvedAudioUrl;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await _channel.initializeEngine();
      _subscription = _channel.watchEvents().listen(
        _handleEvent,
        onError: (Object error) {
          if (mounted) setState(() => _error = error);
        },
      );
      final payload = await _channel.getInitialPayload();
      if (mounted) {
        setState(() => _payload = payload);
        if (extractWebUrl(payload?.text) != null) {
          unawaited(_inspectOptions());
        }
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _handleEvent(BitShareEvent event) {
    if (!mounted) return;
    switch (event) {
      case ShareReceivedEvent():
        setState(() {
          _payload = event.payload;
          _resetTask(clearInspection: true);
        });
        if (extractWebUrl(event.payload.text) != null) {
          unawaited(_inspectOptions());
        }
      case DownloadProgressEvent():
        if (_taskId != null && event.taskId != _taskId) return;
        setState(() {
          _taskId ??= event.taskId;
          _progress = event.progress;
          _stage = event.stage;
          _startingDownload = false;
        });
      case TaskCompletedEvent():
        if (_taskId != null && event.taskId != _taskId) return;
        setState(() {
          _taskId = event.taskId;
          _completedTask = event;
          _progress = 100;
          _stage = 'completed';
          _startingDownload = false;
        });
        if (event.showDonationPrompt) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_showDonationDialog());
          });
        }
      case TaskFailedEvent():
        if (_taskId != null && event.taskId != _taskId) return;
        setState(() {
          _taskError = event.message;
          _stage = 'failed';
          _startingDownload = false;
        });
      case TaskCancelledEvent():
        if (_taskId != null && event.taskId != _taskId) return;
        setState(_resetTask);
      case UnknownBitShareEvent():
        break;
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Align(
        alignment: Alignment.bottomCenter,
        child: SafeArea(
          minimum: const EdgeInsets.all(12),
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            elevation: 18,
            borderRadius: BorderRadius.circular(28),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 620,
                maxHeight: MediaQuery.sizeOf(context).height * 0.9,
              ),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 12, 22, 22),
                  child: _buildContent(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 42,
          height: 4,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.outlineVariant,
            borderRadius: BorderRadius.circular(99),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            key: const Key('close-button'),
            tooltip: 'Cerrar',
            onPressed: _close,
            icon: const Icon(Icons.close),
          ),
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.fromLTRB(0, 6, 0, 22),
            child: CircularProgressIndicator(),
          )
        else if (_error != null)
          const _CompactMessage(
            icon: Icons.error_outline,
            message: 'No se pudo leer el enlace.',
          )
        else if (_payload == null || !_payload!.hasContent)
          const _CompactMessage(
            icon: Icons.link_off_outlined,
            message: 'No se recibió un enlace.',
          )
        else
          _buildDownloadArea(context),
        const SizedBox(height: 20),
        Divider(color: Theme.of(context).colorScheme.outlineVariant),
        const SizedBox(height: 8),
        Text(
          'powered by BitStation',
          key: const Key('panel-footer'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'PressStart2P',
            fontSize: 8,
            height: 1.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildDownloadArea(BuildContext context) {
    final completed = _completedTask;
    if (completed != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _CompactMessage(
            icon: Icons.check_circle_outline,
            message: 'Descarga completada.',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('share-result-button'),
            onPressed: () => unawaited(_channel.shareResult(completed.taskId)),
            icon: const Icon(Icons.share_outlined),
            label: const Text('Compartir'),
          ),
        ],
      );
    }

    final isActive =
        _startingDownload ||
        (_taskId != null && _stage != 'failed' && _stage != null);
    if (isActive) {
      final progressValue = _progress <= 0 ? null : _progress / 100;
      final status = _stage == 'publishing'
          ? 'Guardando…'
          : _stage == 'initializing'
          ? 'Preparando…'
          : 'Descargando…';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(value: progressValue),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: Text(status)),
              if (_progress > 0) Text('${_progress.toStringAsFixed(0)} %'),
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('cancel-download-button'),
            onPressed: _taskId == null
                ? null
                : () => unawaited(_channel.cancelDownload(_taskId!)),
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('Cancelar'),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_inspection == null) ...[
          if (_inspectionError != null) ...[
            _CompactMessage(
              icon: Icons.error_outline,
              message: _inspectionError!,
              isError: true,
            ),
            if (!_isUnsupportedContentError) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('retry-inspection-button'),
                      onPressed: _inspecting ? null : _inspectOptions,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reintentar'),
                    ),
                  ),
                  if (_loginProvider != null) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        key: const Key('login-button'),
                        onPressed: (_inspecting || _loggingIn)
                            ? null
                            : () => unawaited(_login(_loginProvider!)),
                        icon: _loggingIn
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.login_rounded),
                        label: const Text('Iniciar sesión'),
                      ),
                    ),
                  ],
                ],
              ),
              if (_loginProvider != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Bit-Share no recibe tu contraseña. La sesión se consulta '
                  'localmente y solo después de tu autorización explícita.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ] else if (_downloadUrl == null)
            const _CompactMessage(
              icon: Icons.link_off_outlined,
              message: 'No se recibió un enlace web válido.',
            )
          else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Column(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 14),
                  Text('Buscando opciones…'),
                ],
              ),
            ),
        ] else
          _buildOptions(context, _inspection!),
        if (_taskError != null) ...[
          const SizedBox(height: 12),
          _CompactMessage(
            icon: Icons.error_outline,
            message: _taskError!,
            isError: true,
          ),
          if (_loginProvider != null) ...[
            const SizedBox(height: 4),
            FilledButton.icon(
              key: const Key('login-button-retry'),
              onPressed: _loggingIn
                  ? null
                  : () => unawaited(_login(_loginProvider!)),
              icon: _loggingIn
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login_rounded),
              label: const Text('Iniciar sesión y reintentar'),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildOptions(BuildContext context, MediaInspection inspection) {
    final selectedResolution = inspection.resolutions
        .where((item) => item.height == _selectedHeight)
        .firstOrNull;
    final estimatedBytes = _mode == DownloadMode.audio
        ? inspection.audioEstimatedBytes
        : selectedResolution?.estimatedBytes;
    final fitsStorage = _mode == DownloadMode.audio
        ? inspection.audioFitsStorage
        : selectedResolution?.fitsStorage;
    final hasVideo = inspection.resolutions.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<DownloadMode>(
          key: const Key('media-mode-selector'),
          segments: [
            ButtonSegment(
              value: DownloadMode.audio,
              enabled: inspection.audioAvailable,
              icon: const Icon(Icons.graphic_eq),
              label: const Text('Audio'),
            ),
            ButtonSegment(
              value: DownloadMode.video,
              enabled: hasVideo,
              icon: const Icon(Icons.movie_outlined),
              label: const Text('Vídeo'),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: (selection) {
            setState(() => _mode = selection.first);
          },
        ),
        if (_mode == DownloadMode.video && hasVideo) ...[
          const SizedBox(height: 14),
          DropdownButtonFormField<int>(
            key: const Key('resolution-selector'),
            initialValue: _selectedHeight,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Resolución',
              prefixIcon: Icon(Icons.high_quality_outlined),
              border: OutlineInputBorder(),
            ),
            items: [
              for (final resolution in inspection.resolutions)
                DropdownMenuItem(
                  value: resolution.height,
                  child: Text(
                    resolution.estimatedBytes == null
                        ? resolution.label
                        : '${resolution.label}  ·  '
                              '${_formatBytes(resolution.estimatedBytes!)}',
                  ),
                ),
            ],
            onChanged: (height) {
              if (height != null) setState(() => _selectedHeight = height);
            },
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Icon(
              fitsStorage == false
                  ? Icons.warning_amber_rounded
                  : Icons.storage_outlined,
              size: 19,
              color: fitsStorage == false
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                fitsStorage == false
                    ? 'Archivo ≈ ${_formatBytes(estimatedBytes ?? 0)}; '
                          '${_formatBytes(inspection.availableBytes)} libres. '
                          'Falta espacio temporal.'
                    : estimatedBytes == null
                    ? 'Tamaño no disponible.'
                    : 'Tamaño estimado: ${_formatBytes(estimatedBytes)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: fitsStorage == false
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 58,
          child: FilledButton.icon(
            key: const Key('confirm-download-button'),
            onPressed: fitsStorage == false ? null : _startDownload,
            icon: const Icon(Icons.download_outlined),
            label: Text(
              _mode == DownloadMode.audio
                  ? 'Descargar audio'
                  : 'Descargar vídeo',
            ),
          ),
        ),
      ],
    );
  }

  String? get _downloadUrl => extractWebUrl(_payload?.text);

  String? get _loginProvider {
    final url = _downloadUrl;
    return url == null ? null : providerIdForLogin(url);
  }

  /// Content types the download engine can never extract regardless of
  /// session — retrying or logging in would just repeat the same failure,
  /// so both actions are hidden rather than offered dishonestly.
  bool get _isUnsupportedContentError {
    final message = _inspectionError;
    if (message == null) return false;
    return message.startsWith(
          'Esta historia requiere la sesión privada de Instagram.',
        ) ||
        message.startsWith('Esta historia no se puede descargar');
  }

  Future<void> _inspectOptions() async {
    final url = _downloadUrl;
    if (url == null || _inspecting) return;
    setState(() {
      _inspecting = true;
      _inspectionError = null;
      _taskError = null;
    });
    try {
      final effectiveUrl = await _effectiveDownloadUrl() ?? url;
      final inspection = await _channel.inspectUrl(
        effectiveUrl,
        audioUrl: _resolvedAudioUrl,
      );
      if (!mounted) return;
      final defaultResolution = inspection.resolutions
          .where((item) => item.height <= 1080)
          .firstOrNull;
      setState(() {
        _inspection = inspection;
        _mode = inspection.resolutions.isEmpty && inspection.audioAvailable
            ? DownloadMode.audio
            : DownloadMode.video;
        _selectedHeight =
            defaultResolution?.height ??
            inspection.resolutions.firstOrNull?.height;
      });
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _inspectionError =
              error.message ?? 'No se pudieron consultar las opciones.';
        });
      }
    } finally {
      if (mounted) setState(() => _inspecting = false);
    }
  }

  /// Resolves Facebook `/share/` links to their real content URL through
  /// the in-app WebView before inspecting; every other URL passes through
  /// unchanged. Cached in [_resolvedUrl] so the retry-after-login flow and
  /// [_startDownload] reuse the same resolution instead of repeating it.
  Future<String?> _effectiveDownloadUrl() async {
    final url = _downloadUrl;
    if (url == null) return null;
    if (_resolvedUrl != null) return _resolvedUrl;
    if (!needsShareLinkResolution(url)) return url;
    final resolution = await _channel.resolveShareLink(url);
    // A captured Story video URL downloads directly and is strictly more
    // useful than the story *page* URL, which yt-dlp cannot extract at all.
    _resolvedUrl = resolution?.mediaUrl ?? resolution?.resolvedUrl ?? url;
    _resolvedAudioUrl = resolution?.audioUrl;
    return _resolvedUrl;
  }

  Future<void> _login(String providerId) async {
    setState(() => _loggingIn = true);
    try {
      final signedIn = await _channel.openLoginSession(providerId);
      if (!mounted || !signedIn) return;
      // The session just changed, so a URL resolved before logging in (e.g.
      // landing on a login wall) is stale — force it to be resolved again.
      _resolvedUrl = null;
      _resolvedAudioUrl = null;
      if (_inspection == null) {
        await _inspectOptions();
      } else {
        await _startDownload();
      }
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  Future<void> _startDownload() async {
    final url = _downloadUrl;
    final inspection = _inspection;
    if (url == null || inspection == null) return;
    final selectedResolution = inspection.resolutions
        .where((item) => item.height == _selectedHeight)
        .firstOrNull;
    final estimatedBytes = _mode == DownloadMode.audio
        ? inspection.audioEstimatedBytes
        : selectedResolution?.estimatedBytes;
    setState(() {
      _resetTask();
      _startingDownload = true;
      _stage = 'initializing';
    });
    try {
      final effectiveUrl = await _effectiveDownloadUrl() ?? url;
      final taskId = await _channel.startDownload(
        effectiveUrl,
        mode: _mode,
        height: _mode == DownloadMode.video ? _selectedHeight : null,
        estimatedBytes: estimatedBytes,
        audioUrl: _resolvedAudioUrl,
      );
      if (mounted) setState(() => _taskId ??= taskId);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _startingDownload = false;
          _stage = 'failed';
          _taskError = error.message ?? 'No se pudo iniciar la descarga.';
        });
      }
    }
  }

  void _resetTask({bool clearInspection = false}) {
    _taskId = null;
    _progress = 0;
    _stage = null;
    _taskError = null;
    _completedTask = null;
    _startingDownload = false;
    if (clearInspection) {
      _inspection = null;
      _selectedHeight = null;
      _inspectionError = null;
      _mode = DownloadMode.video;
      _resolvedUrl = null;
      _resolvedAudioUrl = null;
    }
  }

  String _formatBytes(int bytes) {
    const gib = 1024 * 1024 * 1024;
    const mib = 1024 * 1024;
    if (bytes >= gib) return '${(bytes / gib).toStringAsFixed(1)} GB';
    if (bytes >= mib) return '${(bytes / mib).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  Future<void> _showDonationDialog() async {
    if (_donationDialogVisible || !mounted) return;
    _donationDialogVisible = true;
    try {
      final shouldDonate = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            icon: const Icon(Icons.favorite_outline),
            title: const Text(
              '¡Gracias por usar Bit-Share!',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'PressStart2P',
                fontSize: 14,
                height: 1.5,
              ),
            ),
            content: const Text(
              'Ya completaste cinco descargas más. '
              'Si Bit-Share te resulta útil, puedes apoyar su desarrollo '
              'con una donación opcional.',
              textAlign: TextAlign.center,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Ahora no'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(dialogContext, true),
                icon: const Icon(Icons.local_cafe_outlined),
                label: const Text('Donar'),
              ),
            ],
          );
        },
      );
      if (shouldDonate == true) {
        await _channel.openDonationPage();
      }
    } finally {
      _donationDialogVisible = false;
    }
  }

  void _close() {
    final taskId = _taskId;
    if (taskId != null && _completedTask == null) {
      unawaited(_channel.cancelDownload(taskId));
    }
    SystemNavigator.pop();
  }
}

class _CompactMessage extends StatelessWidget {
  const _CompactMessage({
    required this.icon,
    required this.message,
    this.isError = false,
  });

  final IconData icon;
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
