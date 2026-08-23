import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/windows_runtime.dart';

/// Keeps the bundled yt-dlp.exe current between Bit-Share releases.
///
/// YouTube invalidates yt-dlp far more often than this app ships an
/// installer, so pinning the engine to the release cycle guarantees weeks of
/// broken downloads at a time. The same four guarantees the Android side
/// works under apply here: the download is checked against the SHA-256
/// GitHub publishes for that asset, it lands in a versioned per-user
/// directory that simply takes precedence over the copy in Program Files,
/// nothing shipped is modified, and a replacement that cannot report its own
/// version is discarded before it is ever used.
enum EngineUpdateStatus { installed, current, unsupported, failed }

class EngineUpdateResult {
  const EngineUpdateResult(this.status, {this.version, this.previous});

  final EngineUpdateStatus status;
  final String? version;
  final String? previous;
}

class YtDlpEngineUpdater {
  const YtDlpEngineUpdater();

  static const _latestUrl =
      'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest';
  static const _stateFile = 'engine-state.json';
  static const _maxBytes = 64 * 1024 * 1024;
  static const _checkInterval = Duration(hours: 12);

  /// Looks for a newer yt-dlp and installs it. [force] skips the throttle
  /// that keeps GitHub from being polled on every launch.
  Future<EngineUpdateResult> checkAndInstall({bool force = false}) async {
    if (!Platform.isWindows) {
      return const EngineUpdateResult(EngineUpdateStatus.unsupported);
    }
    try {
      final directory = Directory(windowsEngineOverrideDirectory());
      await directory.create(recursive: true);
      if (!force && !await _dueForCheck(directory)) {
        return const EngineUpdateResult(EngineUpdateStatus.current);
      }

      final installed = await _installedVersion();
      final latest = await _latestRelease();
      if (latest == null) {
        return const EngineUpdateResult(EngineUpdateStatus.failed);
      }
      if (_compare(latest.version, installed) <= 0) {
        await _recordCheck(directory);
        return EngineUpdateResult(
          EngineUpdateStatus.current,
          version: installed,
        );
      }

      final bytes = await _download(latest);
      if (bytes == null) {
        return const EngineUpdateResult(EngineUpdateStatus.failed);
      }

      final staged = File(joinPath(directory.path, 'yt-dlp.exe.download'));
      await staged.writeAsBytes(bytes, flush: true);
      // A binary that cannot answer --version is not one to hand a download
      // to, whatever its hash said.
      if (!await _runs(staged.path, latest.version)) {
        await _deleteQuietly(staged);
        return const EngineUpdateResult(EngineUpdateStatus.failed);
      }

      final target = File(joinPath(directory.path, 'yt-dlp.exe'));
      final previous = File(joinPath(directory.path, 'yt-dlp.exe.previous'));
      await _deleteQuietly(previous);
      if (await target.exists()) await target.rename(previous.path);
      await staged.rename(target.path);
      await _deleteQuietly(previous);
      await _recordCheck(directory, version: latest.version);
      return EngineUpdateResult(
        EngineUpdateStatus.installed,
        version: latest.version,
        previous: installed,
      );
    } on Object {
      return const EngineUpdateResult(EngineUpdateStatus.failed);
    }
  }

  Future<bool> _dueForCheck(Directory directory) async {
    final file = File(joinPath(directory.path, _stateFile));
    if (!await file.exists()) return true;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return true;
      final millis = (decoded['checkedAt'] as num?)?.toInt();
      if (millis == null) return true;
      final last = DateTime.fromMillisecondsSinceEpoch(millis);
      return DateTime.now().difference(last) >= _checkInterval;
    } on Object {
      return true;
    }
  }

  Future<void> _recordCheck(Directory directory, {String? version}) async {
    final file = File(joinPath(directory.path, _stateFile));
    await file.writeAsString(
      jsonEncode({
        'checkedAt': DateTime.now().millisecondsSinceEpoch,
        'version': ?version,
      }),
    );
  }

  /// The version actually in use, asked of the binary itself rather than
  /// remembered, so a manual swap of the exe is noticed.
  Future<String> _installedVersion() async {
    try {
      final runtime = await resolveWindowsRuntime();
      final result = await Process.run(runtime.ytDlp, const [
        '--version',
      ], stdoutEncoding: utf8, stderrEncoding: utf8);
      if (result.exitCode != 0) return '0';
      return result.stdout.toString().trim().split('\n').first.trim();
    } on Object {
      return '0';
    }
  }

  Future<_LatestEngine?> _latestRelease() async {
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(Uri.parse(_latestUrl))
          .timeout(const Duration(seconds: 20));
      request.headers
        ..set(HttpHeaders.userAgentHeader, 'Bit-Share-Engine/1.0')
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final decoded = jsonDecode(
        await response.transform(utf8.decoder).join(),
      );
      if (decoded is! Map) return null;
      final tag = (decoded['tag_name'] as String? ?? '').trim();
      if (tag.isEmpty) return null;
      for (final raw in (decoded['assets'] as List? ?? const [])) {
        if (raw is! Map) continue;
        if (raw['name'] != 'yt-dlp.exe') continue;
        final url = raw['browser_download_url'] as String?;
        // GitHub publishes the digest alongside the asset as
        // "sha256:<hex>", which saves fetching SHA2-256SUMS separately.
        final digest = (raw['digest'] as String? ?? '');
        if (url == null || !digest.startsWith('sha256:')) continue;
        return _LatestEngine(
          version: tag,
          url: url,
          sha256: digest.substring(7).toLowerCase(),
          size: (raw['size'] as num?)?.toInt() ?? 0,
        );
      }
      return null;
    } on Object {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<List<int>?> _download(_LatestEngine latest) async {
    if (latest.size > _maxBytes) return null;
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(latest.url));
      request.headers.set(HttpHeaders.userAgentHeader, 'Bit-Share-Engine/1.0');
      final response = await request.close();
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > _maxBytes) return null;
      }
      if (sha256.convert(bytes).toString() != latest.sha256) return null;
      return bytes;
    } on Object {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _runs(String path, String expected) async {
    try {
      final result = await Process.run(path, const [
        '--version',
      ], stdoutEncoding: utf8, stderrEncoding: utf8);
      if (result.exitCode != 0) return false;
      final reported = result.stdout.toString().trim();
      return _compare(reported, expected) == 0;
    } on Object {
      return false;
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on Object {
      // Best effort only.
    }
  }

  /// Numeric per-component comparison. yt-dlp tags are dates, so "2026.8.19"
  /// and "2026.08.19" are the same release written two ways and a string
  /// compare would get them wrong.
  static int _compare(String a, String b) {
    final left = _parts(a);
    final right = _parts(b);
    final length = left.length > right.length ? left.length : right.length;
    for (var i = 0; i < length; i++) {
      final x = i < left.length ? left[i] : 0;
      final y = i < right.length ? right[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  static List<int> _parts(String value) => RegExp(r'\d+')
      .allMatches(value)
      .map((match) => int.tryParse(match.group(0)!) ?? 0)
      .toList(growable: false);
}

class _LatestEngine {
  const _LatestEngine({
    required this.version,
    required this.url,
    required this.sha256,
    required this.size,
  });

  final String version;
  final String url;
  final String sha256;
  final int size;
}
