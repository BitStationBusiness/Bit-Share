package com.bitstation.bitshare.download

import android.content.Context
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform

internal object PythonYtDlpEngine {
    @Synchronized
    fun initialize(context: Context) {
        if (!Python.isStarted()) {
            Python.start(AndroidPlatform(context.applicationContext))
        }
    }

    fun inspect(context: Context, url: String, cookiesPath: String? = null): String {
        initialize(context)
        val result = if (cookiesPath != null) {
            module().callAttr("inspect_media", url, cookiesPath)
        } else {
            module().callAttr("inspect_media", url)
        }
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
    ) {
        initialize(context)
        val result = if (cookiesPath != null) {
            module().callAttr(
                "download_media",
                url,
                outputTemplate,
                formatSelector,
                mode,
                ffmpegLocation,
                ffmpegLibraryPath,
                callback,
                cookiesPath,
            )
        } else {
            module().callAttr(
                "download_media",
                url,
                outputTemplate,
                formatSelector,
                mode,
                ffmpegLocation,
                ffmpegLibraryPath,
                callback,
            )
        }
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

    interface DownloadCallback {
        fun onProgressUpdate(progress: Double, etaSeconds: Long)

        fun isCancelled(): Boolean
    }
}
