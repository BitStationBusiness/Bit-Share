package com.bitstation.bitshare.download

import android.content.Context
import com.chaquo.python.Kwarg
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform

internal object PythonYtDlpEngine {
    /// Where downloaded yt-dlp versions live. App-private storage, so the
    /// APK's own copy is never touched and an update can always be undone by
    /// deleting this directory.
    private fun updateRoot(context: Context) =
        java.io.File(context.applicationContext.filesDir, "ytdlp-engine")
            .apply { mkdirs() }
            .absolutePath

    @Synchronized
    fun initialize(context: Context) {
        val started = Python.isStarted()
        if (!started) {
            Python.start(AndroidPlatform(context.applicationContext))
        }
        if (!started) {
            // Must run before bitshare_ytdlp is first imported: sys.path has
            // to be final before `import yt_dlp` binds a version. Failures
            // here are deliberately swallowed — the APK's bundled copy is a
            // perfectly good fallback and downloads must not depend on this.
            runCatching {
                Python.getInstance()
                    .getModule("bitshare_ytdlp_updater")
                    .callAttr("activate", updateRoot(context))
            }
        }
    }

    /// Downloads a newer yt-dlp when PyPI has one. Returns the JSON summary
    /// the Python side produces; it never throws.
    fun updateEngine(context: Context): String {
        initialize(context)
        return updaterModule()
            .callAttr("check_and_install")
            .toJava(String::class.java)
    }

    fun engineStatus(context: Context): String {
        initialize(context)
        return updaterModule().callAttr("status").toJava(String::class.java)
    }

    fun inspect(
        context: Context,
        url: String,
        cookiesPath: String? = null,
        audioUrl: String? = null,
    ): String {
        initialize(context)
        val result = module().callAttr(
            "inspect_media",
            url,
            Kwarg("cookies_path", cookiesPath),
            Kwarg("audio_url", audioUrl),
        )
        return result.toJava(String::class.java)
    }

    fun download(
        context: Context,
        url: String,
        outputTemplate: String,
        formatSelector: String,
        mode: String,
        ffmpegLocation: String,
        ffmpegLibraryPath: String,
        callback: DownloadCallback,
        cookiesPath: String? = null,
        audioUrl: String? = null,
    ) {
        initialize(context)
        val result = module().callAttr(
            "download_media",
            url,
            outputTemplate,
            formatSelector,
            mode,
            ffmpegLocation,
            ffmpegLibraryPath,
            callback,
            Kwarg("cookies_path", cookiesPath),
            Kwarg("audio_url", audioUrl),
        )
        val exitCode = result.toJava(Int::class.java)
        check(exitCode == 0) {
            "El motor terminó con el código $exitCode."
        }
    }

    fun runtimeInfo(context: Context): String {
        initialize(context)
        return module()
            .callAttr("runtime_info")
            .toJava(String::class.java)
    }

    private fun module() =
        Python.getInstance().getModule("bitshare_ytdlp")

    private fun updaterModule() =
        Python.getInstance().getModule("bitshare_ytdlp_updater")

    interface DownloadCallback {
        fun onProgressUpdate(progress: Double, etaSeconds: Long)

        fun isCancelled(): Boolean
    }
}
