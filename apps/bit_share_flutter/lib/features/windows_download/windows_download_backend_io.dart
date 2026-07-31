import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'windows_download_models.dart';

WindowsDownloadBackend createWindowsDownloadBackend() {
  return WindowsProcessDownloadBackend();
}

class WindowsProcessDownloadBackend implements WindowsDownloadBackend {
  WindowsProcessDownloadBackend()
    : _outputDirectory = _join(
        Platform.environment['USERPROFILE'] ?? Directory.current.path,
        'Downloads',
        'Bit-Share',
      );

  static const _resultPrefix = 'bitshare_result:';
  static const _progressPrefix = 'bitshare_progress:';
  static const _minimumWorkingSpace = 64 * 1024 * 1024;

  final String _outputDirectory;
  Process? _activeProcess;
  _RuntimePaths? _runtimePaths;

  @override
  String get outputDirectory => _outputDirectory;

  @override
  Future<WindowsMediaInspection> inspect(
    String url, {
    WindowsBrowserSession? browserSession,
  }) async {
    final runtime = await _resolveRuntime();
    await Directory(_outputDirectory).create(recursive: true);
    final result = await Process.run(
      runtime.ytDlp,
      [
        ..._commonArguments(runtime, browserSession),
        '--dump-single-json',
        '--skip-download',
        url,
      ],
      environment: _processEnvironment(runtime),
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    if (result.exitCode != 0) {
      throw _failureFor(result.stderr.toString());
    }

    final raw = result.stdout.toString().trim();
    final jsonStart = raw.indexOf('{');
    if (jsonStart < 0) {
      throw const WindowsDownloadException(
        'El sitio no devolvió información multimedia válida.',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(raw.substring(jsonStart));
    } on FormatException {
      throw const WindowsDownloadException(
        'No se pudieron interpretar las opciones de descarga.',
      );
    }
    if (decoded is! Map) {
      throw const WindowsDownloadException(
        'El sitio no devolvió opciones compatibles.',
      );
    }

    final info = Map<String, Object?>.from(decoded);
    final formats = (info['formats'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, Object?>.from(item))
        .toList(growable: false);
    final bestAudioBytes = formats
        .where(_isAudioOnly)
        .map(_formatSize)
        .whereType<int>()
        .fold<int?>(
          null,
          (best, size) => best == null || size > best ? size : best,
        );

    final byHeight = <int, int?>{};
    for (final format in formats.where(_hasVideo)) {
      final height = (format['height'] as num?)?.toInt();
      if (height == null || height <= 0) continue;
      final videoBytes = _formatSize(format);
      final includesAudio = _hasAudio(format);
      final combinedBytes = videoBytes == null
          ? null
          : videoBytes + (includesAudio ? 0 : bestAudioBytes ?? 0);
      final previous = byHeight[height];
      if (!byHeight.containsKey(height) ||
          (combinedBytes != null &&
              (previous == null || combinedBytes > previous))) {
        byHeight[height] = combinedBytes;
      }
    }

    final resolutions =
        byHeight.entries
            .map(
              (entry) => WindowsResolution(
                height: entry.key,
                label: '${entry.key}p',
                estimatedBytes: entry.value,
              ),
            )
            .toList()
          ..sort((left, right) => right.height.compareTo(left.height));

    final availableBytes = await _availableBytes();
    final duration = (info['duration'] as num?)?.toDouble();
    final audioBitrate = formats
        .where(_hasAudio)
        .map((format) => (format['abr'] as num?)?.toDouble())
        .whereType<double>()
        .fold<double?>(
          null,
          (best, value) => best == null || value > best ? value : best,
        );
    final audioEstimate =
        bestAudioBytes ??
        (duration != null && audioBitrate != null
            ? (duration * audioBitrate * 1000 / 8).ceil()
            : null);

    return WindowsMediaInspection(
      title: (info['title'] as String?)?.trim().isNotEmpty == true
          ? (info['title'] as String).trim()
          : 'Contenido multimedia',
      providerName:
          (info['extractor_key'] as String?) ??
          (info['extractor'] as String?) ??
          'Web',
      audioAvailable: formats.any(_hasAudio),
      resolutions: resolutions,
      availableBytes: availableBytes,
      audioEstimatedBytes: audioEstimate,
    );
  }

  @override
  Future<WindowsDownloadResult> download(
    String url, {
    required WindowsDownloadMode mode,
    required void Function(WindowsDownloadProgress progress) onProgress,
    int? height,
    int? estimatedBytes,
    WindowsBrowserSession? browserSession,
  }) async {
    if (_activeProcess != null) {
      throw const WindowsDownloadException('Ya hay una descarga activa.');
    }

    final runtime = await _resolveRuntime();
    final output = Directory(_outputDirectory);
    await output.create(recursive: true);
    await _ensureStorage(estimatedBytes, mode);

    final format = mode == WindowsDownloadMode.audio
        ? null
        : height == null
        ? 'bestvideo*+bestaudio/best'
        : 'bestvideo*[height<=$height]+bestaudio/best[height<=$height]';
    final outputTemplate = _join(
      _outputDirectory,
      '%(title).180B [%(id)s].%(ext)s',
    );
    final arguments = <String>[
      ..._commonArguments(runtime, browserSession),
      '--newline',
      '--progress',
      '--progress-template',
      'download:$_progressPrefix%(progress._percent_str)s|%(progress.status)s',
      '--print',
      'after_move:$_resultPrefix%(filepath)s',
      '--output',
      outputTemplate,
      if (mode == WindowsDownloadMode.audio) ...[
        '--extract-audio',
        '--audio-format',
        'mp3',
        '--audio-quality',
        '0',
      ] else ...[
        '--format',
        format!,
        '--merge-output-format',
        'mp4',
      ],
      url,
    ];

    final startedAt = DateTime.now();
    final process = await Process.start(
      runtime.ytDlp,
      arguments,
      environment: _processEnvironment(runtime),
      mode: ProcessStartMode.normal,
    );
    _activeProcess = process;

    String? resultPath;
    final errors = StringBuffer();
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.startsWith(_progressPrefix)) {
            final fields = line.substring(_progressPrefix.length).split('|');
            final numeric = fields.first
                .replaceAll('%', '')
                .replaceAll(RegExp(r'\s+'), '');
            final percent = double.tryParse(numeric) ?? 0;
            onProgress(
              WindowsDownloadProgress(
                percent: percent.clamp(0, 100),
                stage: fields.length > 1 ? fields[1] : 'downloading',
              ),
            );
          } else if (line.startsWith(_resultPrefix)) {
            resultPath = line.substring(_resultPrefix.length).trim();
          }
        })
        .asFuture<void>();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (errors.length < 65536) errors.writeln(line);
        })
        .asFuture<void>();

    try {
      final exitCode = await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      if (exitCode != 0) {
        throw _failureFor(errors.toString());
      }

      final resolvedPath =
          _safeResultPath(resultPath) ??
          await _newestOutputCreatedAfter(output, startedAt);
      if (resolvedPath == null) {
        throw const WindowsDownloadException(
          'La descarga terminó, pero no se encontró el archivo final.',
        );
      }
      onProgress(
        const WindowsDownloadProgress(percent: 100, stage: 'completed'),
      );
      return WindowsDownloadResult(filePath: resolvedPath);
    } finally {
      if (identical(_activeProcess, process)) _activeProcess = null;
    }
  }

  @override
  Future<void> cancel() async {
    final process = _activeProcess;
    if (process == null) return;
    await Process.run(
      'taskkill.exe',
      ['/PID', '${process.pid}', '/T', '/F'],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    _activeProcess = null;
  }

  @override
  Future<void> openOutputDirectory() async {
    await Directory(_outputDirectory).create(recursive: true);
    await Process.start('explorer.exe', [
      _outputDirectory,
    ], mode: ProcessStartMode.detached);
  }

  @override
  Future<void> openLoginPage(
    String url,
    WindowsBrowserSession browserSession,
  ) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        !uri.hasAuthority ||
        uri.userInfo.isNotEmpty) {
      throw const WindowsDownloadException('El enlace no es válido.');
    }
    final browser = await _findBrowser(browserSession);
    await Process.start(browser, [
      uri.toString(),
    ], mode: ProcessStartMode.detached);
  }

  Future<String> _findBrowser(WindowsBrowserSession browserSession) async {
    final programFiles =
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final programFilesX86 =
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final candidates = switch (browserSession) {
      WindowsBrowserSession.edge => [
        _join(
          programFilesX86,
          'Microsoft',
          'Edge',
          'Application',
          'msedge.exe',
        ),
        _join(programFiles, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
      ],
      WindowsBrowserSession.chrome => [
        _join(programFiles, 'Google', 'Chrome', 'Application', 'chrome.exe'),
        _join(programFilesX86, 'Google', 'Chrome', 'Application', 'chrome.exe'),
        _join(localAppData, 'Google', 'Chrome', 'Application', 'chrome.exe'),
      ],
      WindowsBrowserSession.firefox => [
        _join(programFiles, 'Mozilla Firefox', 'firefox.exe'),
        _join(programFilesX86, 'Mozilla Firefox', 'firefox.exe'),
      ],
    };
    for (final candidate in candidates) {
      if (await File(candidate).exists()) return candidate;
    }
    final commandName = switch (browserSession) {
      WindowsBrowserSession.edge => 'msedge.exe',
      WindowsBrowserSession.chrome => 'chrome.exe',
      WindowsBrowserSession.firefox => 'firefox.exe',
    };
    if (await _commandExists(commandName)) return commandName;
    throw WindowsDownloadException(
      'No se encontró ${browserSession.label} en este equipo.',
    );
  }

  List<String> _commonArguments(
    _RuntimePaths runtime,
    WindowsBrowserSession? browserSession,
  ) {
    return [
      '--ignore-config',
      '--no-playlist',
      '--no-warnings',
      '--windows-filenames',
      '--trim-filenames',
      '190',
      '--encoding',
      'utf-8',
      '--ffmpeg-location',
      runtime.ffmpeg,
      if (runtime.deno case final String deno) ...[
        '--js-runtimes',
        'deno:$deno',
        '--remote-components',
        'ejs:github',
      ],
      if (browserSession != null) ...[
        '--cookies-from-browser',
        browserSession.ytDlpName,
      ],
    ];
  }

  Map<String, String> _processEnvironment(_RuntimePaths runtime) {
    final currentPath = Platform.environment['PATH'] ?? '';
    final runtimeDirectory = File(runtime.ytDlp).parent.path;
    return {
      ...Platform.environment,
      'PATH':
          '$runtimeDirectory;${File(runtime.ffmpeg).parent.path};$currentPath',
      'PYTHONUTF8': '1',
    };
  }

  Future<_RuntimePaths> _resolveRuntime() async {
    final cached = _runtimePaths;
    if (cached != null) return cached;

    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      _join(executableDirectory, 'runtime'),
      _join(Directory.current.path, 'windows', 'runtime'),
      _join(Directory.current.path, 'runtime'),
    ];
    for (final directory in candidates) {
      final ytDlp = File(_join(directory, 'yt-dlp.exe'));
      final ffmpeg = File(_join(directory, 'ffmpeg.exe'));
      if (await ytDlp.exists() && await ffmpeg.exists()) {
        final deno = File(_join(directory, 'deno.exe'));
        return _runtimePaths = _RuntimePaths(
          ytDlp: ytDlp.path,
          ffmpeg: ffmpeg.path,
          deno: await deno.exists() ? deno.path : null,
        );
      }
    }

    if (await _commandExists('yt-dlp.exe') &&
        await _commandExists('ffmpeg.exe')) {
      return _runtimePaths = const _RuntimePaths(
        ytDlp: 'yt-dlp.exe',
        ffmpeg: 'ffmpeg.exe',
      );
    }
    throw const WindowsDownloadException(
      'Falta el motor multimedia de Windows. Ejecuta '
      'tools/setup_windows_runtime.ps1 y vuelve a compilar.',
    );
  }

  Future<bool> _commandExists(String executable) async {
    try {
      final result = await Process.run(
        'where.exe',
        [executable],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  Future<int> _availableBytes() async {
    final absolute = Directory(_outputDirectory).absolute.path;
    final match = RegExp(r'^([A-Za-z]:\\)').firstMatch(absolute);
    final driveRoot = match?.group(1);
    if (driveRoot == null) return 0;
    try {
      final environment = {
        ...Platform.environment,
        'BITSHARE_DRIVE': driveRoot,
      };
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "[System.IO.DriveInfo]::new(\$env:BITSHARE_DRIVE).AvailableFreeSpace",
        ],
        environment: environment,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      return result.exitCode == 0
          ? int.tryParse(result.stdout.toString().trim()) ?? 0
          : 0;
    } on ProcessException {
      return 0;
    }
  }

  Future<void> _ensureStorage(
    int? estimatedBytes,
    WindowsDownloadMode mode,
  ) async {
    if (estimatedBytes == null || estimatedBytes <= 0) return;
    final available = await _availableBytes();
    if (available <= 0) return;
    final multiplier = mode == WindowsDownloadMode.video ? 2 : 1;
    final required = estimatedBytes * multiplier + _minimumWorkingSpace;
    if (available < required) {
      throw WindowsDownloadException(
        'No hay espacio suficiente. Se necesitan aproximadamente '
        '${_formatBytes(required)} libres.',
      );
    }
  }

  String? _safeResultPath(String? candidate) {
    if (candidate == null || candidate.isEmpty) return null;
    final absolute = File(candidate).absolute.path;
    final outputPrefix =
        '${Directory(_outputDirectory).absolute.path}${Platform.pathSeparator}';
    if (!absolute.toLowerCase().startsWith(outputPrefix.toLowerCase()) ||
        !File(absolute).existsSync()) {
      return null;
    }
    return absolute;
  }

  Future<String?> _newestOutputCreatedAfter(
    Directory output,
    DateTime startedAt,
  ) async {
    File? newest;
    await for (final entity in output.list(followLinks: false)) {
      if (entity is! File) continue;
      final modified = await entity.lastModified();
      if (modified.isBefore(startedAt.subtract(const Duration(seconds: 2)))) {
        continue;
      }
      if (newest == null || modified.isAfter(await newest.lastModified())) {
        newest = entity;
      }
    }
    return newest?.absolute.path;
  }

  WindowsDownloadException _failureFor(String rawError) {
    final error = rawError.toLowerCase();
    if (_requiresAuthentication(error)) {
      return const WindowsDownloadException(
        'Este contenido necesita una sesión. Inicia sesión en tu navegador '
        'y autoriza a Bit-Share a usar esa sesión localmente.',
        authenticationRequired: true,
      );
    }
    if (error.contains('drm') || error.contains('protected content')) {
      return const WindowsDownloadException(
        'El contenido utiliza una protección que Bit-Share no puede eludir.',
      );
    }
    if (error.contains('unsupported url') ||
        error.contains('no video formats found')) {
      return const WindowsDownloadException(
        'Este sitio no ofrece una descarga compatible para ese enlace.',
      );
    }
    if (error.contains('timed out') ||
        error.contains('unable to download') ||
        error.contains('network')) {
      return const WindowsDownloadException(
        'No se pudo conectar con el sitio. Revisa la conexión y reintenta.',
      );
    }
    return const WindowsDownloadException(
      'No se pudo descargar este contenido. Reintenta o comprueba que '
      'el enlace siga disponible.',
    );
  }

  bool _requiresAuthentication(String error) {
    return [
      'sign in',
      'login required',
      'log in',
      'authentication required',
      'cookies',
      'not logged in',
      'private video',
      'members-only',
      'age-restricted',
    ].any(error.contains);
  }

  static bool _hasVideo(Map<String, Object?> format) {
    final codec = format['vcodec'] as String?;
    return codec != null && codec != 'none';
  }

  static bool _hasAudio(Map<String, Object?> format) {
    final codec = format['acodec'] as String?;
    return codec != null && codec != 'none';
  }

  static bool _isAudioOnly(Map<String, Object?> format) {
    return _hasAudio(format) && !_hasVideo(format);
  }

  static int? _formatSize(Map<String, Object?> format) {
    return (format['filesize'] as num?)?.toInt() ??
        (format['filesize_approx'] as num?)?.toInt();
  }

  static String _formatBytes(int bytes) {
    const gib = 1024 * 1024 * 1024;
    const mib = 1024 * 1024;
    if (bytes >= gib) return '${(bytes / gib).toStringAsFixed(1)} GB';
    if (bytes >= mib) return '${(bytes / mib).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}

class _RuntimePaths {
  const _RuntimePaths({required this.ytDlp, required this.ffmpeg, this.deno});

  final String ytDlp;
  final String ffmpeg;
  final String? deno;
}

String _join(
  String first,
  String second, [
  String? third,
  String? fourth,
  String? fifth,
]) {
  final separator = Platform.pathSeparator;
  final values = [first, second, ?third, ?fourth, ?fifth];
  return values
      .map((value) => value.replaceAll(RegExp(r'[\\/]+$'), ''))
      .join(separator);
}
