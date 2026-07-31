String? extractWebUrl(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;

  final match = RegExp(
    r'https?://[^\s<>"]+',
    caseSensitive: false,
  ).firstMatch(text);
  final candidate = match?.group(0)?.replaceFirst(RegExp(r'[.,;!?)\]}]+$'), '');
  final uri = candidate == null ? null : Uri.tryParse(candidate);
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.toString();
}
