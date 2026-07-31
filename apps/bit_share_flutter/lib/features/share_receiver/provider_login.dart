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

/// URLs the download engine can never extract on its own, so the in-app
/// WebView (BitShareChannel.resolveShareLink) has to run *before* yt-dlp
/// ever sees them:
///
/// - Facebook's `/share/<id>/` short links only resolve to their real
///   content URL (a `/watch`, `/videos/`, `/reel/` or `/stories/` URL)
///   through a client-side redirect that yt-dlp's own HTTP client cannot
///   reliably follow — Facebook resets the connection for it.
/// - Facebook `/stories/...` pages have no yt-dlp extractor at all; the
///   video only exists as CDN requests the WebView can observe while the
///   story actually plays (see LoginSessionActivity's resolve mode).
///
/// Instagram stories are deliberately *not* here — see
/// [canRecoverWithShareLinkResolution].
bool needsShareLinkResolution(String url) {
  final uri = Uri.tryParse(url);
  final host = uri?.host.toLowerCase();
  if (host == null) return false;
  final isFacebook = host == 'facebook.com' || host.endsWith('.facebook.com');
  if (isFacebook && uri!.path.startsWith('/share/')) return true;
  if (isFacebook && uri!.path.startsWith('/stories/')) return true;
  return false;
}

/// Instagram `/stories/...` pages *do* have a yt-dlp extractor
/// (`instagram:story`), and with the session Bit-Share already stores it
/// resolves the exact story the link points at, by id. That is strictly
/// better than the WebView capture, which can only watch whichever DASH
/// tracks the player happens to fetch — an inherent race that picked up a
/// neighbouring, preloaded story whenever the viewer paused on Instagram's
/// "¿Ver historia?" interstitial.
///
/// So these go straight to the engine, and the capture is kept only as a
/// last resort for when the engine fails (no session yet, for instance).
bool canRecoverWithShareLinkResolution(String url) {
  final uri = Uri.tryParse(url);
  final host = uri?.host.toLowerCase();
  if (host == null) return false;
  final isInstagram =
      host == 'instagram.com' || host.endsWith('.instagram.com');
  return isInstagram && uri!.path.startsWith('/stories/');
}
