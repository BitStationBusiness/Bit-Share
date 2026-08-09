import 'dart:io';

import 'media_library.dart';
import 'media_library_android.dart';
import 'media_library_windows.dart';

/// Android and Windows both compile against `dart:io`, so the split between
/// them happens here at runtime rather than through a second conditional
/// import.
MediaLibrary createMediaLibrary() {
  if (Platform.isAndroid) return AndroidMediaLibrary();
  if (Platform.isWindows) return WindowsMediaLibrary();
  throw const MediaLibraryException(
    'La galería solo está disponible en Android y Windows.',
  );
}
