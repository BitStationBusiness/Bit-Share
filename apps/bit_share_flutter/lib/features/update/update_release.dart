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
