import 'package:flutter/services.dart';

import 'media_library.dart';

/// Channel shared by the gallery and the editor. Kept apart from
/// `bitshare/methods`, which serves the share-sheet download flow.
const galleryMethodChannel = MethodChannel('bitshare/gallery');

/// Backed by MediaStore, restricted to the `Bit-Share` album Android's
/// download step publishes into.
class AndroidMediaLibrary implements MediaLibrary {
  AndroidMediaLibrary({MethodChannel? methods})
    : _methods = methods ?? galleryMethodChannel;

  final MethodChannel _methods;

  @override
  String get storageLocationLabel => 'Películas · Música · Bit-Share';

  @override
  bool get canShare => true;

  @override
  bool get canRevealInFileManager => false;

  @override
  bool get canCopyToClipboard => false;

  @override
  Future<MediaLibrarySnapshot> load() async {
    try {
      final response = await _methods.invokeMapMethod<Object?, Object?>(
        'list',
      );
      if (response == null) return MediaLibrarySnapshot.empty;
      final rawItems = response['items'];
      return MediaLibrarySnapshot(
        items: rawItems is List
            ? rawItems
                  .whereType<Map>()
                  .map(
                    (item) => MediaItem.fromMap(Map<Object?, Object?>.from(item)),
                  )
                  .toList(growable: false)
            : const [],
        accessRestricted: response['accessRestricted'] as bool? ?? false,
      );
    } on PlatformException catch (error) {
      throw MediaLibraryException(
        error.message ?? 'No se pudo leer la galería de Bit-Share.',
      );
    }
  }

  @override
  Future<bool> requestAccess() async {
    try {
      return await _methods.invokeMethod<bool>('requestAccess') ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<String?> thumbnailPath(MediaItem item) async {
    try {
      return await _methods.invokeMethod<String>('thumbnail', {'id': item.id});
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<int> delete(Iterable<MediaItem> items) async {
    final ids = items.map((item) => item.id).toList(growable: false);
    if (ids.isEmpty) return 0;
    try {
      return await _methods.invokeMethod<int>('delete', {'ids': ids}) ?? 0;
    } on PlatformException catch (error) {
      throw MediaLibraryException(
        error.message ?? 'Android no permitió borrar el archivo.',
      );
    }
  }

  @override
  Future<bool> share(MediaItem item) async {
    try {
      return await _methods.invokeMethod<bool>('share', {'id': item.id}) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> revealInFileManager(MediaItem item) async {
    throw UnsupportedError('Android no expone la carpeta de descargas.');
  }

  @override
  Future<void> copyToClipboard(MediaItem item) async {
    throw UnsupportedError('Android comparte archivos con el menú Compartir.');
  }
}
