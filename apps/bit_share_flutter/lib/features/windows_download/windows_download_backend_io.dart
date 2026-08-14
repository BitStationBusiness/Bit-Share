import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/windows_runtime.dart';
import 'windows_download_models.dart';

WindowsDownloadBackend createWindowsDownloadBackend() {
  return WindowsProcessDownloadBackend();
}

class WindowsProcessDownloadBackend implements WindowsDownloadBackend {
  WindowsProcessDownloadBackend()
    : _outputDirectory = windowsLibraryDirectory();

  static const _resultPrefix = 'bitshare_result:';
  static const _progressPrefix = 'bitshare_progress:';
  static const _minimumWorkingSpace = 64 * 1024 * 1024;
  static const _nativeChannel = MethodChannel('bitshare/windows');

  final String _outputDirectory;
  Process? _activeProcess;

  String _sessionRoot() {
    return joinPath(
      Platform.environment['LOCALAPPDATA'] ?? Directory.current.path,
      'Bit-Share',
    );
  }

  /// Bit-Share signs in using a browser profile it owns rather than the
  /// user's everyday one. Two reasons: Chromium holds an exclusive lock on
  /// its cookie database while running, so reading the normal profile fails
  /// outright unless the user quits their browser entirely; and this way
  /// Bit-Share only ever touches a profile created for it, never the
  /// user's own browsing data.
  String _sessionProfilePath(WindowsBrowserSession browserSession) {
    return joinPath(_sessionRoot(), 'browser-sessions', browserSession.name);
  }

  /// Where the browser profile's cookies get exported to, once. Reading the
  /// profile directly needs the browser closed *every* time, so the export
  /// is what actually makes a session reusable: later runs just read this
  /// file and neither open nor close anything.
  String _cookieFilePath(WindowsBrowserSession browserSession) {
    return joinPath(_sessionRoot(), 'sessions', '${browserSession.name}.txt');
  }

  /// A session saved by an earlier run — including earlier launches of the
  /// app, which is the whole point: signing in once should keep working
  /// after Bit-Share is closed and reopened.
  String? _storedCookieFile() {
    for (final browserSession in WindowsBrowserSession.values) {
      final file = File(_cookieFilePath(browserSession));
      if (file.existsSync() && file.lengthSync() > 0) return file.path;
    }
    return null;
  }

  /// Chromium keeps an exclusive lock on the cookie database until its
  /// *entire* process tree exits — the GPU, network, storage and renderer
  /// helper processes all hold it open too, not just the window itself.
  /// Killing every process individually races those helpers respawning, so
  /// this finds the root browser process for Bit-Share's own profile (the
  /// one launch flag reliably identifies: it has the profile directory but
  /// no `--type=`, which only the root process lacks) and kills that whole
  /// tree in one `taskkill /T`. A follow-up sweep catches anything that
  /// still matches the profile path in case more than one root existed.
  /// Only processes whose command line points at Bit-Share's own profile
  /// directory are ever touched — the user's normal browser is never
  /// affected, even when it is the same executable.
  Future<void> _closeSessionBrowser(
    WindowsBrowserSession browserSession,
  ) async {
    // `Start-Process -Wait` on taskkill.exe is unreliable here — it can
    // return before the tree is actually gone — so taskkill is invoked
    // directly and its own exit is what's waited on.
    const script = r'''
$ErrorActionPreference = 'SilentlyContinue'
$dir = $env:BITSHARE_SESSION_PROFILE
$matched = Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -and $_.CommandLine.Contains($dir) }
$roots = $matched | Where-Object { $_.CommandLine -notmatch '--type=' }
foreach ($root in $roots) {
  & taskkill.exe /PID $root.ProcessId /T /F | Out-Null
}
Start-Sleep -Milliseconds 300
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -and $_.CommandLine.Contains($dir) } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
''';
    await Process.run(
      'powershell.exe',
      ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script],
      environment: {
        ...Platform.environment,
        'BITSHARE_SESSION_PROFILE': _sessionProfilePath(browserSession),
      },
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    // Chromium releases the database a moment after the tree exits.
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }

  /// Cookie arguments for a yt-dlp invocation.
  ///
  /// - [browserSession] given (the user just signed in and asked Bit-Share
  ///   to use that session): closes the profile's browser window, then asks
  ///   yt-dlp to read the live profile *and* dump what it finds into the
  ///   persisted file in the same call — that dump is what makes the session
  ///   outlive this run.
  /// - [browserSession] omitted: reuses a persisted file from any earlier
  ///   run, including previous launches of the app, with no browser
  ///   involved at all. This is what lets a session signed in once keep
  ///   working after Bit-Share is closed and reopened.
  Future<List<String>> _cookieArguments(
    WindowsBrowserSession? browserSession,
  ) async {
    if (browserSession != null) {
      final file = _cookieFilePath(browserSession);
      await Directory(File(file).parent.path).create(recursive: true);
      await _closeSessionBrowser(browserSession);
      return [
        '--cookies-from-browser',
        '${browserSession.ytDlpName}:${_sessionProfilePath(browserSession)}',
        '--cookies',
        file,
      ];
    }
    final stored = _storedCookieFile();
    return stored == null ? const [] : ['--cookies', stored];
  }

  @override
  String get outputDirectory => _outputDirectory;

  @override
  Future<WindowsMediaInspection> inspect(
    String url, {
    WindowsBrowserSession? browserSession,
  }) async {
    final runtime = await _resolveRuntime();
    await Directory(_outputDirectory).create(recursive: true);
    final cookieArguments = await _cookieArguments(browserSession);
    final result = await Process.run(
      runtime.ytDlp,
      [
        ..._commonArguments(runtime),
        ...cookieArguments,
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

    // A playlist or album link (e.g. a YouTube Music album URL) has no
    // top-level `formats` — the downloadable media lives one level down, in
    // `entries`. Every entry gets downloaded, so estimates below are summed
    // across all of them instead of read from a single track.
    final isPlaylist = info['_type'] == 'playlist';
    final entries = isPlaylist
        ? (info['entries'] as List? ?? const [])
              .whereType<Map>()
              .map((item) => Map<String, Object?>.from(item))
              .toList(growable: false)
        : [info];
    final trackCount = entries.isEmpty ? 1 : entries.length;

    final byHeight = <int, int?>{};
    var audioAvailable = false;
    int? totalAudioBytes;
    var missingAudioEstimate = false;

    for (final entry in entries) {
      final formats = (entry['formats'] as List? ?? const [])
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

      if (formats.any(_hasAudio)) audioAvailable = true;
      final duration = (entry['duration'] as num?)?.toDouble();
      final audioBitrate = formats
          .where(_hasAudio)
          .map((format) => (format['abr'] as num?)?.toDouble())
          .whereType<double>()
          .fold<double?>(
            null,
            (best, value) => best == null || value > best ? value : best,
          );
      final entryAudioEstimate =
          bestAudioBytes ??
          (duration != null && audioBitrate != null
              ? (duration * audioBitrate * 1000 / 8).ceil()
              : null);
      if (entryAudioEstimate == null) {
        missingAudioEstimate = true;
      } else {
        totalAudioBytes = (totalAudioBytes ?? 0) + entryAudioEstimate;
      }

      // Only the first entry sizes the video-resolution list: mixing
      // playlists rarely share every height, and per-entry totals would
      // stop meaning anything once summed against different tracks.
      if (!identical(entry, entries.first)) continue;
      for (final format in formats.where(_hasVideo)) {
        final height = (format['height'] as num?)?.toInt();
        if (height == null || height <= 0) continue;
        final videoBytes = _formatSize(format);
        final includesAudio = _hasAudio(format);
        final combinedBytes = videoBytes == null
            ? null
            : (videoBytes + (includesAudio ? 0 : bestAudioBytes ?? 0)) *
                  trackCount;
        final previous = byHeight[height];
        if (!byHeight.containsKey(height) ||
            (combinedBytes != null &&
                (previous == null || combinedBytes > previous))) {
          byHeight[height] = combinedBytes;
        }
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
    final audioEstimate = missingAudioEstimate ? null : totalAudioBytes;
    final rawTitle = (info['title'] as String?)?.trim();
    final title = rawTitle?.isNotEmpty == true
        ? rawTitle!
        : 'Contenido multimedia';

    return WindowsMediaInspection(
      title: trackCount > 1 ? '$title ($trackCount pistas)' : title,
      providerName:
          (info['extractor_key'] as String?) ??
          (info['extractor'] as String?) ??
          'Web',
      audioAvailable: audioAvailable,
      resolutions: resolutions,
      availableBytes: availableBytes,
      audioEstimatedBytes: audioEstimate,
      trackCount: trackCount,
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
    final cookieArguments = await _cookieArguments(browserSession);

    final format = mode == WindowsDownloadMode.audio
        ? null
        : height == null
        ? 'bestvideo*+bestaudio/best'
        : 'bestvideo*[height<=$height]+bestaudio/best[height<=$height]';
    final outputTemplate = joinPath(
      _outputDirectory,
      '%(title).180B [%(id)s].%(ext)s',
    );
    final arguments = <String>[
      ..._commonArguments(runtime),
      ...cookieArguments,
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

    // A playlist/album link produces one `after_move:` line per track, not
    // one for the whole run — every path gets kept, not just the last.
    final resultPaths = <String>[];
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
            resultPaths.add(line.substring(_resultPrefix.length).trim());
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

      final resolvedPaths = resultPaths
          .map(_safeResultPath)
          .whereType<String>()
          .toList(growable: false);
      final resolvedPath = resolvedPaths.isNotEmpty
          ? resolvedPaths.first
          : await _newestOutputCreatedAfter(output, startedAt);
      if (resolvedPath == null) {
        throw const WindowsDownloadException(
          'La descarga terminó, pero no se encontró el archivo final.',
        );
      }
      onProgress(
        const WindowsDownloadProgress(percent: 100, stage: 'completed'),
      );
      return WindowsDownloadResult(
        filePath: resolvedPath,
        fileCount: resolvedPaths.isEmpty ? 1 : resolvedPaths.length,
      );
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
  Future<void> copyFileToClipboard(String filePath) async {
    try {
      final copied = await _nativeChannel.invokeMethod<bool>('copyFile', {
        'path': filePath,
      });
      if (copied != true) {
        throw const WindowsDownloadException(
          'No se pudo copiar el archivo al portapapeles.',
        );
      }
    } on PlatformException catch (error) {
      throw WindowsDownloadException(
        error.message ?? 'No se pudo copiar el archivo al portapapeles.',
      );
    }
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
    final profile = _sessionProfilePath(browserSession);
    await Directory(profile).create(recursive: true);
    await _closeSessionBrowser(browserSession);
    await Process.start(browser, [
      ..._sessionProfileArguments(browserSession, profile),
      uri.toString(),
    ], mode: ProcessStartMode.detached);
  }

  List<String> _sessionProfileArguments(
    WindowsBrowserSession browserSession,
    String profile,
  ) {
    return switch (browserSession) {
      WindowsBrowserSession.edge || WindowsBrowserSession.chrome => [
        '--user-data-dir=$profile',
        '--no-first-run',
        '--no-default-browser-check',
        // Without this, a Chromium profile signed into the OS account pulls
        // the user's real bookmarks, passwords and extensions down into what
        // is supposed to be a throwaway session directory — and pushes
        // anything done here back up to that account.
        '--disable-sync',
      ],
      WindowsBrowserSession.firefox => ['-profile', profile, '-no-remote'],
    };
  }

  Future<String> _findBrowser(WindowsBrowserSession browserSession) async {
    final programFiles =
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final programFilesX86 =
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final candidates = switch (browserSession) {
      WindowsBrowserSession.edge => [
        joinPath(
          programFilesX86,
          'Microsoft',
          'Edge',
          'Application',
          'msedge.exe',
        ),
        joinPath(
          programFiles,
          'Microsoft',
          'Edge',
          'Application',
          'msedge.exe',
        ),
      ],
      WindowsBrowserSession.chrome => [
        joinPath(programFiles, 'Google', 'Chrome', 'Application', 'chrome.exe'),
        joinPath(
          programFilesX86,
          'Google',
          'Chrome',
          'Application',
          'chrome.exe',
        ),
        joinPath(localAppData, 'Google', 'Chrome', 'Application', 'chrome.exe'),
      ],
      WindowsBrowserSession.firefox => [
        joinPath(programFiles, 'Mozilla Firefox', 'firefox.exe'),
        joinPath(programFilesX86, 'Mozilla Firefox', 'firefox.exe'),
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
    if (await commandExists(commandName)) return commandName;
    throw WindowsDownloadException(
      'No se encontró ${browserSession.label} en este equipo.',
    );
  }

  List<String> _commonArguments(WindowsRuntimePaths runtime) {
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
    ];
  }

  Map<String, String> _processEnvironment(WindowsRuntimePaths runtime) {
    final currentPath = Platform.environment['PATH'] ?? '';
    final runtimeDirectory = File(runtime.ytDlp).parent.path;
    return {
      ...Platform.environment,
      'PATH':
          '$runtimeDirectory;${File(runtime.ffmpeg).parent.path};$currentPath',
      'PYTHONUTF8': '1',
    };
  }

  Future<WindowsRuntimePaths> _resolveRuntime() async {
    try {
      return await resolveWindowsRuntime();
    } on WindowsRuntimeException catch (error) {
      throw WindowsDownloadException(error.message);
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
    // Chromium keeps an exclusive lock on its cookie database, so this is
    // what a still-running browser looks like. It used to fall through to
    // the generic "could not download" message, which pointed the user at
    // the link instead of at the real cause.
    if (error.contains('could not copy') && error.contains('cookie')) {
      return const WindowsDownloadException(
        'El navegador de la sesión sigue abierto y bloquea sus cookies. '
        'Ciérralo por completo y pulsa “Reintentar con mi sesión”.',
        authenticationRequired: true,
      );
    }
    if (error.contains('could not find') && error.contains('cookie')) {
      return const WindowsDownloadException(
        'Todavía no hay una sesión guardada. Pulsa “Abrir e iniciar sesión”, '
        'inicia sesión en la ventana que abre Bit-Share y reintenta.',
        authenticationRequired: true,
      );
    }
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
