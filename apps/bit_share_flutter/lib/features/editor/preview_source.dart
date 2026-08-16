import '../gallery/media_item.dart';
import 'preview_source_model.dart';
import 'preview_source_stub.dart'
    if (dart.library.io) 'preview_source_io.dart'
    as implementation;

export 'preview_source_model.dart';

Future<EditorPreviewSource> prepareEditorPreview(MediaItem item) =>
    implementation.prepareEditorPreview(item);
