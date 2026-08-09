import 'media_item.dart';
import 'media_library_stub.dart'
    if (dart.library.io) 'media_library_io.dart'
    as implementation;

export 'media_item.dart';

/// Everything the gallery knows after a refresh.
class MediaLibrarySnapshot {
  const MediaLibrarySnapshot({
    required this.items,
    this.accessRestricted = false,
  });

  static const empty = MediaLibrarySnapshot(items: []);

  final List<MediaItem> items;

  /// True when the platform is only letting Bit-Share see the files this
  /// installation created, so older downloads may be missing until the user
  /// grants media access. Always false on Windows, which has no such gate.
  final bool accessRestricted;
}

class MediaLibraryException implements Exception {
  const MediaLibraryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Read/manage access to the media Bit-Share itself downloaded. Deliberately
/// scoped to Bit-Share's own folders: this is a library for the app's
/// downloads, not a general-purpose gallery over the user's whole device.
abstract interface class MediaLibrary {
  /// Human-readable description of where the files live, shown in the
  /// gallery's empty state so the user knows what it is looking at.
  String get storageLocationLabel;

  /// Whether the platform offers a system share sheet.
  bool get canShare;

  /// Whether the platform can show the file in a system file manager.
  bool get canRevealInFileManager;

  /// Whether the file itself (not its path) can be put on the clipboard, so
  /// it can be pasted straight into another application.
  bool get canCopyToClipboard;

  Future<MediaLibrarySnapshot> load();

  /// Asks for whatever permission the platform needs to see every Bit-Share
  /// download rather than only this installation's. Returns the access state
  /// afterwards; a no-op returning true where no permission exists.
  Future<bool> requestAccess();

  /// Absolute path to a cached JPEG poster frame, or null when one could not
  /// be produced (an audio file with no cover art, a corrupt video).
  Future<String?> thumbnailPath(MediaItem item);

  /// Permanently removes [items]. Returns how many were actually deleted.
  Future<int> delete(Iterable<MediaItem> items);

  Future<bool> share(MediaItem item);

  Future<void> revealInFileManager(MediaItem item);

  Future<void> copyToClipboard(MediaItem item);
}

MediaLibrary createMediaLibrary() => implementation.createMediaLibrary();
