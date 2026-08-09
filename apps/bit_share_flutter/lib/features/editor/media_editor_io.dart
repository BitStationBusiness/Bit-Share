import 'dart:io';

import 'media_editor.dart';
import 'media_editor_android.dart';
import 'media_editor_windows.dart';

MediaEditor createMediaEditor() {
  if (Platform.isAndroid) return AndroidMediaEditor();
  if (Platform.isWindows) return WindowsMediaEditor();
  throw const MediaEditException(
    'El editor solo está disponible en Android y Windows.',
  );
}
