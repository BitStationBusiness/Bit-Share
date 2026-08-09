import 'media_editor.dart';

/// Web cannot run ffmpeg, so the editor is never reachable there. The factory
/// still has to exist for the conditional import to compile.
MediaEditor createMediaEditor() {
  throw const MediaEditException(
    'El editor solo está disponible en Android y Windows.',
  );
}
