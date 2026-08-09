import 'media_library.dart';

/// Web has no local Bit-Share download folder to browse, so the gallery is
/// never reachable there. The factory still has to exist for the conditional
/// import to compile.
MediaLibrary createMediaLibrary() {
  throw const MediaLibraryException(
    'La galería solo está disponible en Android y Windows.',
  );
}
