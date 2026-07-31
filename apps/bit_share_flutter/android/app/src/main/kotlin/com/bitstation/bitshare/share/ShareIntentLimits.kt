package com.bitstation.bitshare.share

internal object ShareIntentLimits {
    const val MAX_ITEMS = 20
    const val MAX_TEXT_LENGTH = 100_000
    const val MAX_MIME_LENGTH = 255

    fun acceptsMime(mimeType: String?): Boolean {
        if (mimeType == null) return true
        return mimeType == "text/plain" ||
            mimeType.startsWith("image/") ||
            mimeType.startsWith("audio/") ||
            mimeType.startsWith("video/")
    }
}
