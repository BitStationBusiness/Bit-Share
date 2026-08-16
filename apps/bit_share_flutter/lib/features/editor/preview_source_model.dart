/// Media source used only by the editor's live preview.
///
/// Windows can decode some web-oriented codecs correctly but too slowly for
/// interactive editing. In that case [path] points at a cached H.264 proxy;
/// exports continue to use the untouched original file.
class EditorPreviewSource {
  const EditorPreviewSource({
    required this.uri,
    this.path,
    this.optimized = false,
  });

  final String uri;
  final String? path;
  final bool optimized;
}
