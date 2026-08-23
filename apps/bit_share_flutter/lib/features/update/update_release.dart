import 'package:flutter/foundation.dart';

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.tag,
    required this.notes,
    required this.downloadUrl,
    required this.assetSizeBytes,
    this.sha256,
  });

  final String version;
  final String tag;
  final String notes;
  final String downloadUrl;
  final int assetSizeBytes;
  final String? sha256;
}

/// Why an update check ended the way it did.
///
/// The checker used to answer `null` for every outcome, so "you are already
/// up to date" and "GitHub never replied" were indistinguishable. The
/// automatic check can treat both as silence, but a check the user asked for
/// has to say which one happened, and a failed one is worth retrying while an
/// up-to-date one is not.
enum UpdateCheckStatus {
  /// A newer release exists and carries an installer for this platform.
  updateAvailable,

  /// The newest release is this one, or older.
  upToDate,

  /// Not a released build, or a platform with no installer. Never retried.
  unsupported,

  /// The network, GitHub, or the response shape let us down. Worth retrying.
  failed,
}

@immutable
class UpdateCheckResult {
  const UpdateCheckResult(this.status, [this.release]);

  const UpdateCheckResult.upToDate() : this(UpdateCheckStatus.upToDate);
  const UpdateCheckResult.unsupported() : this(UpdateCheckStatus.unsupported);
  const UpdateCheckResult.failed() : this(UpdateCheckStatus.failed);

  final UpdateCheckStatus status;

  /// Only set when [status] is [UpdateCheckStatus.updateAvailable].
  final UpdateRelease? release;

  bool get isRetryable => status == UpdateCheckStatus.failed;
}

/// Compares two dotted version strings, e.g. "v1.2.10" vs "1.2.9" -> 1.
/// Missing components count as 0, so "1.2" == "1.2.0".
int compareVersions(String a, String b) {
  final partsA = _versionParts(a);
  final partsB = _versionParts(b);
  final length = partsA.length > partsB.length ? partsA.length : partsB.length;
  for (var i = 0; i < length; i++) {
    final valueA = i < partsA.length ? partsA[i] : 0;
    final valueB = i < partsB.length ? partsB[i] : 0;
    if (valueA != valueB) return valueA.compareTo(valueB);
  }
  return 0;
}

List<int> _versionParts(String value) {
  final normalized = value.startsWith(RegExp('[vV]'))
      ? value.substring(1)
      : value;
  return normalized
      .split(RegExp(r'[.\-+]'))
      .map((part) => int.tryParse(part) ?? 0)
      .toList(growable: false);
}
