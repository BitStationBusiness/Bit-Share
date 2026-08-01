package com.bitstation.bitshare.media

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import java.io.File
import java.io.IOException

internal data class PublishedMedia(
    val uri: Uri,
    val displayName: String,
    val mimeType: String,
)

internal class MediaStoreRepository(
    private val context: Context,
) {
    fun publish(source: File): PublishedMedia {
        check(source.isFile && source.length() > 0L) {
            "El resultado descargado no es un archivo válido."
        }

        val mimeType = detectMimeType(source)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            val fallback = File(
                context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS),
                source.name,
            )
            source.copyTo(fallback, overwrite = true)
            return PublishedMedia(Uri.fromFile(fallback), fallback.name, mimeType)
        }

        val destination = destinationFor(mimeType)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, source.name)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(
                MediaStore.MediaColumns.RELATIVE_PATH,
                "${destination.directory}/Bit-Share",
            )
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val collection = destination.collection
        val resolver = context.contentResolver
        val uri = resolver.insert(collection, values)
            ?: throw IOException("Android no pudo crear el archivo de destino.")

        try {
            resolver.openOutputStream(uri, "w")?.use { output ->
                source.inputStream().use { input -> input.copyTo(output) }
            } ?: throw IOException("Android no pudo abrir el archivo de destino.")

            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return PublishedMedia(uri, source.name, mimeType)
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
    }

    private fun detectMimeType(file: File): String {
        val extension = file.extension.lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: when (extension) {
                "mp4", "m4v" -> "video/mp4"
                "webm" -> "video/webm"
                "m4a" -> "audio/mp4"
                "mp3" -> "audio/mpeg"
                else -> "application/octet-stream"
            }
    }

    private fun destinationFor(mimeType: String): MediaDestination {
        return when {
            mimeType.startsWith("video/") -> MediaDestination(
                directory = Environment.DIRECTORY_MOVIES,
                collection = MediaStore.Video.Media.getContentUri(
                    MediaStore.VOLUME_EXTERNAL_PRIMARY,
                ),
            )
            mimeType.startsWith("image/") -> MediaDestination(
                directory = Environment.DIRECTORY_PICTURES,
                collection = MediaStore.Images.Media.getContentUri(
                    MediaStore.VOLUME_EXTERNAL_PRIMARY,
                ),
            )
            mimeType.startsWith("audio/") -> MediaDestination(
                directory = Environment.DIRECTORY_MUSIC,
                collection = MediaStore.Audio.Media.getContentUri(
                    MediaStore.VOLUME_EXTERNAL_PRIMARY,
                ),
            )
            else -> MediaDestination(
                directory = Environment.DIRECTORY_DOWNLOADS,
                collection = MediaStore.Downloads.getContentUri(
                    MediaStore.VOLUME_EXTERNAL_PRIMARY,
                ),
            )
        }
    }

    private data class MediaDestination(
        val directory: String,
        val collection: Uri,
    )
}
