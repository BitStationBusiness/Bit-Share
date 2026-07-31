/// Compile-time version identity, injected at build time via
/// `--dart-define=APP_VERSION=<pubspec version>` (see
/// tools/build_release.ps1, the single source of truth for the version).
///
/// A debug `flutter run` never sets this define, so it falls back to a value
/// that cannot match a published tag — the auto-updater treats that as "not a
/// real build" and stays quiet instead of offering to overwrite a dev tree.
const String kAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '0.0.0',
);

bool get kIsVersionedBuild => kAppVersion != '0.0.0';
