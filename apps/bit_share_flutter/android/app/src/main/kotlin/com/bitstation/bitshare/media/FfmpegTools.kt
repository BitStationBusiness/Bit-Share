package com.bitstation.bitshare.media

import android.content.Context
import android.system.Os
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
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

    /**
     * Unpacks the archives `libffmpeg.so` links against. Both calls are
     * idempotent and near-free after the first run, so every entry point that
     * is about to spawn ffmpeg can simply call this instead of hoping some
     * other feature ran first.
     */
    fun initializeRuntime(context: Context) {
        // FFmpeg's Android package depends on shared libraries bundled in
        // youtubedl-android's Python package, so that one is unpacked first.
        YoutubeDL.init(context)
        FFmpeg.getInstance().init(context)
    }

    /**
     * Directories holding libavcodec and friends.
     *
     * `libffmpeg.so` is a *dynamically linked executable*: on its own it is
     * barely 300 KB and declares `libavcodec.so.61`, `libavformat.so.61` and
     * six more as NEEDED. Those live inside youtubedl-android's package
     * archives, which is why they are not on the system loader path. Spawning
     * ffmpeg without this on `LD_LIBRARY_PATH` kills the process before it
     * parses its first argument — the failure the media editor was reporting
     * as "no se pudo procesar la edición".
     */
    fun libraryPath(context: Context): String {
        val packages = File(
            context.noBackupFilesDir,
            "youtubedl-android/packages",
        )
        return listOf(
            File(packages, "ffmpeg/usr/lib"),
            File(packages, "python/usr/lib"),
        ).joinToString(File.pathSeparator) { it.absolutePath }
    }

    /**
     * Starts the bundled ffmpeg with everything it needs to actually run.
     * stderr is kept separate so callers can quote the real diagnostic
     * instead of inventing a generic one.
     */
    fun start(context: Context, arguments: List<String>): Process {
        initializeRuntime(context)
        val binary = File(prepare(context), "ffmpeg").absolutePath
        return ProcessBuilder(listOf(binary) + arguments)
            .redirectErrorStream(false)
            .apply { environment()["LD_LIBRARY_PATH"] = libraryPath(context) }
            .start()
    }

    /** Blocking one-shot run, for short jobs with no progress to report. */
    fun run(context: Context, arguments: List<String>): Result<Unit> {
        val process = start(context, arguments)
        val diagnostics = StringBuilder()
        val drain = Thread {
            process.errorStream.bufferedReader().forEachLine { line ->
                if (diagnostics.length < 8192) diagnostics.appendLine(line)
            }
        }.apply { isDaemon = true; start() }
        process.inputStream.bufferedReader().forEachLine { }
        val exitCode = process.waitFor()
        drain.join(2_000)
        return if (exitCode == 0) {
            Result.success(Unit)
        } else {
            Result.failure(IllegalStateException(diagnostics.toString().trim()))
        }
    }
}
