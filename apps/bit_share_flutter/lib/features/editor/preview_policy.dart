/// Codecs that Windows Media Foundation can open but commonly decodes too
/// slowly for an editing preview. They are transcoded only in the temporary
/// preview cache; H.264 and other native-friendly sources stay untouched.
bool requiresOptimizedWindowsPreview(String? codec) =>
    const {'av1', 'vp8', 'vp9'}.contains(codec?.trim().toLowerCase());
