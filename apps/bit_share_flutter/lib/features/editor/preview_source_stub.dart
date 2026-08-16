import '../gallery/media_item.dart';
import 'preview_source_model.dart';

Future<EditorPreviewSource> prepareEditorPreview(MediaItem item) async =>
    EditorPreviewSource(uri: item.uri, path: item.path);
