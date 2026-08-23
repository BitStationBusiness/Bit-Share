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

  /// Looks for the newest published, non-draft, non-prerelease version that
  /// is newer than [kAppVersion] and carries an installer for this platform.
  ///
  /// Every outcome is named rather than collapsed into null: the caller needs
  /// to know whether a silent result meant "already current" (leave it) or
  /// "the check never got an answer" (retry, and say so if the user asked).
  Future<UpdateCheckResult> checkForUpdate() async {
    if (!kIsVersionedBuild) return const UpdateCheckResult.unsupported();
    if (!Platform.isWindows && !Platform.isAndroid) {
      return const UpdateCheckResult.unsupported();
    }

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
        // Includes GitHub's 403 rate-limit answer, which a later attempt
        // from the same address can well get past.
        return const UpdateCheckResult.failed();
      }
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! List) return const UpdateCheckResult.failed();

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
      if (latest == null) return const UpdateCheckResult.upToDate();

      final tag = latest['tag_name'] as String;
      final version = tag.startsWith(RegExp('[vV]')) ? tag.substring(1) : tag;
      if (compareVersions(version, kAppVersion) <= 0) {
        return const UpdateCheckResult.upToDate();
      }

      final asset = _pickAsset(latest);
      // A newer tag with no installer for this platform is not something the
      // user can act on, and no amount of retrying will produce one.
      if (asset == null) return const UpdateCheckResult.upToDate();
      final assetName = asset['name'] as String? ?? '';

      return UpdateCheckResult(
        UpdateCheckStatus.updateAvailable,
        UpdateRelease(
          version: version,
          tag: tag,
          notes: (latest['body'] as String? ?? '').trim(),
          downloadUrl: asset['browser_download_url'] as String,
          assetSizeBytes: (asset['size'] as num?)?.toInt() ?? 0,
          sha256: _extractSha256(latest['body'] as String?, assetName),
        ),
      );
    } on Object {
      return const UpdateCheckResult.failed();
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

  /// Release notes may carry a hash next to the asset's own file name (a
  /// manual publishing habit, not a hard requirement) — e.g. from a
  /// SHA256SUMS.txt pasted into the body. Matching is scoped to [assetName]
  /// on purpose: a release ships both an .exe and an .apk, so grabbing the
  /// first 64-hex sequence in the whole body would silently pin the wrong
  /// platform's hash. When nothing matches, the size + file-signature checks
  /// in UpdateInstaller still apply.
  String? _extractSha256(String? notes, String assetName) {
    if (notes == null || assetName.isEmpty) return null;
    final pattern = RegExp(
      '${RegExp.escape(assetName)}[^\\n]{0,80}?([0-9a-fA-F]{64})',
      caseSensitive: false,
    );
    return pattern.firstMatch(notes)?.group(1)?.toLowerCase();
  }
}
