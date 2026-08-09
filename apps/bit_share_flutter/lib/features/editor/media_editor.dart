import '../gallery/media_item.dart';
import 'edit_request.dart';
import 'media_editor_stub.dart'
    if (dart.library.io) 'media_editor_io.dart'
    as implementation;

export 'edit_request.dart';

class MediaEditException implements Exception {
  const MediaEditException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Raised when the user cancels an export, so callers can tell an abort from
/// a genuine failure and stay quiet about it.
class MediaEditCancelled implements Exception {
  const MediaEditCancelled();
}

/// Runs an edit and puts the result back in the Bit-Share library.
abstract interface class MediaEditor {
  /// Reads the true duration and frame size of [item]. The gallery listing
  /// may not carry them — Windows has no metadata store to read from and
  /// Android leaves them null for files it never indexed — and the editor
  /// cannot lay out a trim bar without a duration.
  Future<MediaItem> probe(MediaItem item);

  /// Exports [request] as a new file next to the original. The source is
  /// never modified: an edit that went wrong should cost the user nothing.
  Future<MediaItem> export(
    MediaEditRequest request, {
    required void Function(double progress) onProgress,
  });

  /// Stops the running export. The partial output is discarded.
  Future<void> cancel();
}

MediaEditor createMediaEditor() => implementation.createMediaEditor();
