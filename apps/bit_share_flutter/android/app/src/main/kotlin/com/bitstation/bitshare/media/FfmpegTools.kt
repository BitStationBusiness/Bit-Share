package com.bitstation.bitshare.media

import android.content.Context
import android.system.Os
import java.io.File

/**
 * Symlinks (or copies, when symlinking is unavailable) the ffmpeg/ffprobe
 * shared libraries bundled by youtubedl-android into a directory with plain
 * executable names, since both yt-dlp and Bit-Share's own subprocess calls
 * expect `ffmpeg`/`ffprobe` on a resolvable path rather than `libffmpeg.so`.
 */
internal object FfmpegTools {
    fun prepare(context: Context): File {
        val toolsDirectory = File(
            context.noBackupFilesDir,
            "bitshare-media-tools",
        ).apply { mkdirs() }
        listOf("ffmpeg", "ffprobe").forEach { toolName ->
            val source = File(
                context.applicationInfo.nativeLibraryDir,
                "lib$toolName.so",
            )
            check(source.isFile) {
                "No se encontró $toolName en el paquete Android."
            }
            val target = File(toolsDirectory, toolName)
            runCatching { Os.remove(target.absolutePath) }
            runCatching {
                Os.symlink(source.absolutePath, target.absolutePath)
            }.getOrElse {
                runCatching { Os.remove(target.absolutePath) }
                source.copyTo(target, overwrite = true)
                check(target.setExecutable(true, false)) {
                    "No se pudo preparar $toolName."
                }
            }
        }
        return toolsDirectory
    }
}
