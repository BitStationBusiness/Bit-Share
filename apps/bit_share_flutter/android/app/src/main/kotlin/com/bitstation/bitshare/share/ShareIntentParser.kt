package com.bitstation.bitshare.share

import android.content.Intent
import android.net.Uri
import android.os.Build
import java.time.Instant
import java.util.UUID

internal object ShareIntentParser {
    fun parse(intent: Intent?, sourcePackage: String?): Map<String, Any?>? {
        if (intent == null) return null
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) {
            return null
        }

        val mimeType = intent.type?.take(ShareIntentLimits.MAX_MIME_LENGTH)
        if (!ShareIntentLimits.acceptsMime(mimeType)) return null

        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)
            ?.toString()
            ?.take(ShareIntentLimits.MAX_TEXT_LENGTH)
        val uris = collectContentUris(intent)
        if (text.isNullOrBlank() && uris.isEmpty()) return null

        return mapOf(
            "id" to UUID.randomUUID().toString(),
            "sourcePackage" to sourcePackage,
            "action" to intent.action.orEmpty(),
            "mimeType" to mimeType,
            "text" to text,
            "uris" to uris.map(Uri::toString),
            "inputKind" to inferInputKind(mimeType, text, uris),
            "receivedAt" to Instant.now().toString(),
        )
    }

    private fun collectContentUris(intent: Intent): List<Uri> {
        val uris = linkedSetOf<Uri>()
        intent.clipData?.let { clip ->
            val count = minOf(clip.itemCount, ShareIntentLimits.MAX_ITEMS)
            for (index in 0 until count) {
                addIfSafe(uris, clip.getItemAt(index).uri)
            }
        }

        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            streamList(intent).orEmpty()
                .take(ShareIntentLimits.MAX_ITEMS)
                .forEach { addIfSafe(uris, it) }
        } else {
            addIfSafe(uris, singleStream(intent))
        }
        return uris.take(ShareIntentLimits.MAX_ITEMS)
    }

    private fun addIfSafe(target: MutableSet<Uri>, uri: Uri?) {
        if (uri?.scheme == "content") {
            target += uri
        }
    }

    @Suppress("DEPRECATION")
    private fun singleStream(intent: Intent): Uri? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }
    }

    @Suppress("DEPRECATION")
    private fun streamList(intent: Intent): ArrayList<Uri>? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
        }
    }

    private fun inferInputKind(
        mimeType: String?,
        text: String?,
        uris: List<Uri>,
    ): String {
        if (uris.size > 1) return "multiUri"
        if (uris.size == 1) {
            return when {
                mimeType?.startsWith("image/") == true -> "imageUri"
                mimeType?.startsWith("audio/") == true -> "audioUri"
                mimeType?.startsWith("video/") == true -> "videoUri"
                else -> "unknown"
            }
        }

        val parsed = text?.trim()?.let(Uri::parse)
        return if (parsed?.scheme == "http" || parsed?.scheme == "https") {
            "url"
        } else {
            "text"
        }
    }
}
