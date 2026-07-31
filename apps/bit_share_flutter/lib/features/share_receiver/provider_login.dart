/// Providers LoginSessionActivity (Android) knows how to open a login page
/// for. Mirrors `ProviderLogin.kt` — kept in sync manually since it's a
/// short, stable list, not worth threading through a platform channel call.
const _loginProviders = <String, List<String>>{
  'facebook': ['facebook.com', 'fb.watch'],
  'instagram': ['instagram.com'],
  'tiktok': ['tiktok.com'],
  'x': ['x.com', 'twitter.com'],
  'threads': ['threads.com'],
};

/// Returns the provider id to pass to `openLoginSession` for [url], or null
/// when this host has no known login flow.
String? providerIdForLogin(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase();
  if (host == null || host.isEmpty) return null;
  for (final entry in _loginProviders.entries) {
    final matches = entry.value.any(
      (suffix) => host == suffix || host.endsWith('.$suffix'),
    );
    if (matches) return entry.key;
  }
  return null;
}

/// Two cases need the in-app WebView before yt-dlp ever sees the URL:
///
/// - Facebook's `/share/<id>/` short links only resolve to their real
///   content URL (a `/watch`, `/videos/`, `/reel/` or `/stories/` URL)
///   through a client-side redirect that yt-dlp's own HTTP client cannot
///   reliably follow — Facebook resets the connection for it.
/// - Facebook and Instagram `/stories/...` pages are never extractable by
///   yt-dlp directly — their video (and, on Instagram, audio) only exist as
///   CDN requests the WebView can observe while the story actually plays
///   (see LoginSessionActivity's resolve mode).
///
/// Either way BitShareChannel.resolveShareLink does the work instead of
/// handing the page URL straight to yt-dlp.
bool needsShareLinkResolution(String url) {
  final uri = Uri.tryParse(url);
  final host = uri?.host.toLowerCase();
  if (host == null) return false;
  final isFacebook = host == 'facebook.com' || host.endsWith('.facebook.com');
  final isInstagram =
      host == 'instagram.com' || host.endsWith('.instagram.com');
  if (isFacebook && uri!.path.startsWith('/share/')) return true;
  if (isFacebook && uri!.path.startsWith('/stories/')) return true;
  if (isInstagram && uri!.path.startsWith('/stories/')) return true;
  return false;
}
