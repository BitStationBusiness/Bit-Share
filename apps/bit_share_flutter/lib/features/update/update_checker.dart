import 'dart:convert';
import 'dart:io';

import '../../app/app_version.dart';
import 'update_release.dart';

const _repo = 'BitStationBusiness/Bit-Share';

/// The LIST endpoint, not /releases/latest: a repo with no published
/// releases answers 404 there, and that would be indistinguishable from
/// "GitHub is unreachable". The list answers 200 with [] instead.
const _releasesUrl = 'https://api.github.com/repos/$_repo/releases?per_page=10';

class UpdateChecker {
  const UpdateChecker();

  /// Returns the newest published, non-draft, non-prerelease version when it
  /// is newer than [kAppVersion] and carries an installer for this platform.
  /// Returns null on any failure, on debug builds, or when already current —
  /// the caller decides silence vs. surfacing an error, and today it always
  /// stays silent, matching a check that should never interrupt startup.
  Future<UpdateRelease?> checkForUpdate() async {
    if (!kIsVersionedBuild) return null;
    if (!Platform.isWindows && !Platform.isAndroid) return null;

    final client = HttpClient();
    try {
      final request = await client
          .getUrl(Uri.parse(_releasesUrl))
          .timeout(const Duration(seconds: 15));
      request.headers
        ..set(HttpHeaders.userAgentHeader, 'Bit-Share-Updater/1.0')
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! List) return null;

      Map<String, Object?>? latest;
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final release = Map<String, Object?>.from(entry);
        if (release['draft'] == true || release['prerelease'] == true) {
          continue;
        }
        final tag = release['tag_name'] as String?;
        if (tag == null || tag.isEmpty) continue;
        latest = release;
        break;
      }
      if (latest == null) return null;

      final tag = latest['tag_name'] as String;
      final version = tag.startsWith(RegExp('[vV]')) ? tag.substring(1) : tag;
      if (compareVersions(version, kAppVersion) <= 0) return null;

      final asset = _pickAsset(latest);
      if (asset == null) return null;

      return UpdateRelease(
        version: version,
        tag: tag,
        notes: (latest['body'] as String? ?? '').trim(),
        downloadUrl: asset['browser_download_url'] as String,
        assetSizeBytes: (asset['size'] as num?)?.toInt() ?? 0,
        sha256: _extractSha256(latest['body'] as String?),
      );
    } on Object {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Map<String, Object?>? _pickAsset(Map<String, Object?> release) {
    final assets = (release['assets'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, Object?>.from(item))
        .toList(growable: false);
    final suffix = Platform.isWindows ? '.exe' : '.apk';
    final matches = assets.where(
      (asset) =>
          (asset['name'] as String? ?? '').toLowerCase().endsWith(suffix),
    );
    if (matches.isEmpty) return null;
    if (!Platform.isWindows) return matches.first;
    final setupNamed = RegExp('setup|install', caseSensitive: false);
    return matches.firstWhere(
      (asset) => setupNamed.hasMatch(asset['name'] as String? ?? ''),
      orElse: () => matches.first,
    );
  }

  /// release notes may carry "SHA-256: `<hex>`" (a manual publishing habit,
  /// not a hard requirement): when present it is enforced by UpdateInstaller,
  /// when absent the size + file-signature checks still apply.
  String? _extractSha256(String? notes) {
    if (notes == null) return null;
    final match = RegExp(r'\b([0-9a-fA-F]{64})\b').firstMatch(notes);
    return match?.group(1)?.toLowerCase();
  }
}
