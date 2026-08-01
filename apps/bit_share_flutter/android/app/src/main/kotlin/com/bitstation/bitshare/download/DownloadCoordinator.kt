package com.bitstation.bitshare.download

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Environment
import android.os.StatFs
import android.system.Os
import android.util.Log
import com.bitstation.bitshare.donation.DonationPromptPolicy
import com.bitstation.bitshare.media.MediaStoreRepository
import com.bitstation.bitshare.media.PublishedMedia
import com.bitstation.bitshare.providers.ProviderRegistry
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import org.json.JSONObject

internal class DownloadCoordinator(
    context: Context,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    private val appContext = context.applicationContext
    private val executor = Executors.newSingleThreadExecutor()
    private val results = ConcurrentHashMap<String, PublishedMedia>()
    private val activeTasks = ConcurrentHashMap.newKeySet<String>()
    private val cancelledTasks = ConcurrentHashMap.newKeySet<String>()
    private val mediaStore = MediaStoreRepository(appContext)
    private val preferences = appContext.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )

    fun inspect(
        rawUrl: String,
        onSuccess: (Map<String, Any?>) -> Unit,
        onError: (String) -> Unit,
        audioUrl: String? = null,
    ) {
        val normalizedUrl = rawUrl.trim()
        val provider = ProviderRegistry.resolve(normalizedUrl)
        if (provider == null) {
            onError("Comparte un enlace web público válido.")
            return
        }
        executor.execute {
            try {
                val isDebug =
                    appContext.applicationInfo.flags and
                        ApplicationInfo.FLAG_DEBUGGABLE != 0
                if (isDebug) {
                    Log.d(
                        LOG_TAG,
                        "Python engine: ${PythonYtDlpEngine.runtimeInfo(appContext)}",
                    )
                }
                val info = JSONObject(
                    PythonYtDlpEngine.inspect(
                        appContext,
                        normalizedUrl,
                        cookiesPathFor(provider.id),
                        audioUrl,
                    ),
                )
                val rawFormats = info.optJSONArray("formats")
                val formats = buildList {
                    if (rawFormats == null) return@buildList
                    for (index in 0 until rawFormats.length()) {
                        val rawFormat = rawFormats.optJSONObject(index) ?: continue
                        add(
                            FormatInfo(
                                audioCodec = rawFormat.optString("audioCodec"),
                                videoCodec = rawFormat.optString("videoCodec"),
                                height = rawFormat.optInt("height"),
                                fileSize = rawFormat.optLong("fileSize"),
                                fileSizeApproximate =
                                    rawFormat.optLong("fileSizeApproximate"),
                                audioBitrate = rawFormat.optDouble("audioBitrate"),
                                totalBitrate = rawFormat.optDouble("totalBitrate"),
                            ),
                        )
                    }
                }
                val audioFormats = formats.filter {
                    it.audioCodec.isUsableCodec()
                }
                val bestAudio = audioFormats.maxWithOrNull(
                    compareBy(
                        { it.audioBitrate },
                        { it.totalBitrate },
                        { estimatedBytes(it.fileSize, it.fileSizeApproximate) },
                    ),
                )
                val audioBytes = bestAudio?.let {
                    estimatedBytes(it.fileSize, it.fileSizeApproximate)
                } ?: 0L
                val resolutions = formats
                    .filter { it.height > 0 && it.videoCodec.isUsableCodec() }
                    .groupBy { it.height }
                    .map { (height, candidates) ->
                        val videoOnly =
                            candidates.filter { !it.audioCodec.isUsableCodec() }
                        val selectedPool = videoOnly.ifEmpty { candidates }
                        val selected = selectedPool.maxByOrNull {
                            estimatedBytes(it.fileSize, it.fileSizeApproximate)
                        }
                        val videoBytes = selected?.let {
                            estimatedBytes(it.fileSize, it.fileSizeApproximate)
                        } ?: 0L
                        val estimated = if (videoBytes > 0L) {
                            videoBytes + if (
                                selected?.audioCodec.isUsableCodec()
                            ) {
                                0L
                            } else {
                                audioBytes
                            }
                        } else {
                            0L
                        }
                        mapOf(
                            "height" to height,
                            "label" to "${height}p",
                            "estimatedBytes" to estimated.takeIf { it > 0L },
                            "fitsStorage" to fitsStorage(estimated),
                        )
                    }
                    .sortedByDescending { (it["height"] as Int) }
                if (audioFormats.isEmpty() && resolutions.isEmpty()) {
                    error("El sitio no expone formatos de audio o vídeo.")
                }

                onSuccess(
                    mapOf(
                        "title" to info.optString("title"),
                        "providerName" to provider.displayName,
                        "availableBytes" to availableStorageBytes(),
                        "audioAvailable" to audioFormats.isNotEmpty(),
                        "audioEstimatedBytes" to audioBytes.takeIf { it > 0L },
                        "audioFitsStorage" to fitsStorage(audioBytes),
                        "resolutions" to resolutions,
                    ),
                )
            } catch (error: Throwable) {
                Log.e(
                    LOG_TAG,
                    "Media inspection failed: ${diagnosticCode(error)}",
                    error,
                )
                if (
                    appContext.applicationInfo.flags and
                    ApplicationInfo.FLAG_DEBUGGABLE != 0
                ) {
                    File(appContext.filesDir, "last-inspection-error.log")
                        .writeText(error.stackTraceToString())
                }
                onError(friendlyMessage(error))
            }
        }
    }

    fun start(
        rawUrl: String,
        mode: String,
        height: Int?,
        estimatedSize: Long?,
        audioUrl: String? = null,
    ): String {
        val normalizedUrl = rawUrl.trim()
        val provider = ProviderRegistry.resolve(normalizedUrl)
            ?: throw IllegalArgumentException(
                "Comparte un enlace web público válido.",
            )
        require(mode == "audio" || mode == "video") {
            "Selecciona audio o vídeo."
        }
        if (
            estimatedSize != null &&
            estimatedSize > 0L &&
            fitsStorage(estimatedSize) == false
        ) {
            throw IllegalArgumentException(
                "No hay espacio suficiente para esta descarga.",
            )
        }
        val taskId = UUID.randomUUID().toString()
        activeTasks += taskId
        emit(
            mapOf(
                "type" to "downloadProgress",
                "taskId" to taskId,
                "progress" to 0.0,
                "etaSeconds" to null,
                "stage" to "initializing",
                "providerId" to provider.id,
                "providerName" to provider.displayName,
            ),
        )
        executor.execute {
            runDownload(
                taskId,
                normalizedUrl,
                provider.id,
                provider.displayName,
                mode,
                height,
                audioUrl,
            )
        }
        return taskId
    }

    fun cancel(taskId: String): Boolean {
        if (!activeTasks.contains(taskId)) return false
        cancelledTasks += taskId
        return true
    }

    /**
     * Opens the device gallery instead of a file manager. Finished files are
     * already published through MediaStore in the Bit-Share media albums, so
     * gallery applications can index and present them using their own visual
     * interface.
     */
    fun openLibrary(activity: Activity): Boolean {
        val galleryIntent = Intent.makeMainSelectorActivity(
            Intent.ACTION_MAIN,
            Intent.CATEGORY_APP_GALLERY,
        )
        return try {
            activity.startActivity(galleryIntent)
            true
        } catch (notFound: ActivityNotFoundException) {
            false
        }
    }

    fun share(activity: Activity, taskId: String): Boolean {
        val media = results[taskId] ?: return false
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = media.mimeType
            putExtra(Intent.EXTRA_STREAM, media.uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        activity.startActivity(Intent.createChooser(intent, "Compartir con"))
        return true
    }

    private fun runDownload(
        taskId: String,
        url: String,
        providerId: String,
        providerName: String,
        mode: String,
        height: Int?,
        audioUrl: String? = null,
    ) {
        val taskDir = File(appContext.cacheDir, "tasks/$taskId").apply {
            deleteRecursively()
            mkdirs()
        }
        val isDebug =
            appContext.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        val engineLog = File(appContext.filesDir, "last-engine-output.log")
        val errorLog = File(appContext.filesDir, "last-download-error.log")
        if (isDebug) {
            engineLog.writeText("")
            errorLog.writeText("")
        }
        try {
            // FFmpeg's Android package depends on shared libraries bundled in
            // youtubedl-android's Python package. Initialize both on every
            // fresh installation before exposing the FFmpeg executable.
            YoutubeDL.init(appContext)
            FFmpeg.getInstance().init(appContext)
            emitProgress(taskId, 0f, null, "downloading", providerName)
            val outputTemplate =
                File(taskDir, "%(title).80B [%(id)s].%(ext)s").absolutePath
            val formatSelector = if (mode == "audio") {
                "bestaudio[ext=m4a]/bestaudio"
            } else {
                videoFormatSelector(height)
            }
            val ffmpegLocation = prepareFfmpegTools()
            val packageRoot = File(
                appContext.noBackupFilesDir,
                "youtubedl-android/packages",
            )
            val pythonLibraryDirectory = File(packageRoot, "python/usr/lib")
            check(
                File(pythonLibraryDirectory, "libexpat.so.1").isFile,
            ) {
                "El runtime multimedia no se inicializó completamente."
            }
            val ffmpegLibraryPath = listOf(
                File(packageRoot, "ffmpeg/usr/lib"),
                pythonLibraryDirectory,
            ).joinToString(File.pathSeparator) { it.absolutePath }
            PythonYtDlpEngine.download(
                context = appContext,
                url = url,
                outputTemplate = outputTemplate,
                formatSelector = formatSelector,
                mode = mode,
                ffmpegLocation = ffmpegLocation,
                ffmpegLibraryPath = ffmpegLibraryPath,
                callback = object : PythonYtDlpEngine.DownloadCallback {
                    override fun onProgressUpdate(
                        progress: Double,
                        etaSeconds: Long,
                    ) {
                        emitProgress(
                            taskId,
                            progress.toFloat(),
                            etaSeconds,
                            "downloading",
                            providerName,
                        )
                    }

                    override fun isCancelled(): Boolean {
                        return cancelledTasks.contains(taskId)
                    }
                },
                cookiesPath = cookiesPathFor(providerId),
                audioUrl = audioUrl,
            )
            if (isDebug) {
                engineLog.appendText(
                    taskDir.listFiles()
                        .orEmpty()
                        .joinToString(
                            prefix = "\nFILES\n",
                            separator = "\n",
                        ) { "${it.name}: ${it.length()}" },
                )
            }

            val resultFile = taskDir.listFiles()
                ?.asSequence()
                ?.filter { it.isFile && !it.name.endsWith(".part") }
                ?.maxByOrNull(File::length)
                ?: error("El motor terminó sin producir un archivo.")

            emitProgress(taskId, 100f, 0L, "publishing", providerName)
            val published = mediaStore.publish(resultFile)
            results[taskId] = published
            val previousCount = preferences.getInt(COMPLETED_DOWNLOADS_KEY, 0)
            val completedDownloadCount =
                DonationPromptPolicy.nextCount(previousCount)
            preferences.edit()
                .putInt(COMPLETED_DOWNLOADS_KEY, completedDownloadCount)
                .apply()
            emit(
                mapOf(
                    "type" to "taskCompleted",
                    "taskId" to taskId,
                    "fileName" to published.displayName,
                    "contentUri" to published.uri.toString(),
                    "mimeType" to published.mimeType,
                    "completedDownloadCount" to completedDownloadCount,
                    "showDonationPrompt" to
                        DonationPromptPolicy.shouldPrompt(completedDownloadCount),
                ),
            )
        } catch (error: Throwable) {
            val wasCancelled =
                cancelledTasks.contains(taskId) ||
                    generateSequence(error) { it.cause }
                        .any { "BITSHARE_CANCELLED" in it.message.orEmpty() }
            if (wasCancelled) {
                emit(mapOf("type" to "taskCancelled", "taskId" to taskId))
            } else {
                Log.e(LOG_TAG, "Download failed: ${diagnosticCode(error)}")
                if (isDebug) {
                    Log.e(
                        LOG_TAG,
                        "${error.javaClass.simpleName}: " +
                            sanitizedDiagnostic(error.message),
                        error,
                    )
                    errorLog.writeText(error.stackTraceToString())
                }
            }
            if (!wasCancelled) {
                emit(
                    mapOf(
                        "type" to "taskFailed",
                        "taskId" to taskId,
                        "code" to diagnosticCode(error),
                        "message" to friendlyMessage(error),
                    ),
                )
            }
        } finally {
            activeTasks -= taskId
            cancelledTasks -= taskId
            taskDir.deleteRecursively()
        }
    }

    private fun emitProgress(
        taskId: String,
        progress: Float,
        etaSeconds: Long?,
        stage: String,
        providerName: String,
    ) {
        emit(
            mapOf(
                "type" to "downloadProgress",
                "taskId" to taskId,
                "progress" to progress.toDouble().coerceIn(0.0, 100.0),
                "etaSeconds" to etaSeconds,
                "stage" to stage,
                "providerName" to providerName,
            ),
        )
    }

    private fun videoFormatSelector(height: Int?): String {
        val limit = height?.takeIf { it > 0 }?.let { "[height<=$it]" }.orEmpty()
        return "bestvideo$limit[ext=mp4]+bestaudio[ext=m4a]/" +
            "bestvideo$limit+bestaudio/" +
            "best$limit[ext=mp4][vcodec!=none]/best$limit[vcodec!=none]"
    }

    private fun prepareFfmpegTools(): String {
        val toolsDirectory = File(
            appContext.noBackupFilesDir,
            "bitshare-media-tools",
        ).apply { mkdirs() }
        listOf("ffmpeg", "ffprobe").forEach { toolName ->
            val source = File(
                appContext.applicationInfo.nativeLibraryDir,
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
        return toolsDirectory.absolutePath
    }

    private fun String?.isUsableCodec(): Boolean {
        return !this.isNullOrBlank() && !equals("none", ignoreCase = true)
    }

    private fun estimatedBytes(exact: Long, approximate: Long): Long {
        return exact.takeIf { it > 0L } ?: approximate.takeIf { it > 0L } ?: 0L
    }

    /** Set by LoginSessionActivity once the user explicitly signs in for
     * this provider inside Bit-Share's own WebView (see the auth package).
     * Absent by default — most providers never need it. */
    private fun cookiesPathFor(providerId: String): String? {
        val file = File(appContext.filesDir, "cookies/$providerId.txt")
        return file.takeIf { it.isFile }?.absolutePath
    }

    private fun availableStorageBytes(): Long {
        return StatFs(appContext.cacheDir.absolutePath).availableBytes
    }

    private fun fitsStorage(estimatedSize: Long): Boolean? {
        if (estimatedSize <= 0L) return null
        val workingBytes = estimatedSize
            .coerceAtMost((Long.MAX_VALUE - STORAGE_SAFETY_BYTES) / 3)
            .times(3)
            .plus(STORAGE_SAFETY_BYTES)
        return workingBytes <= availableStorageBytes()
    }

    private fun friendlyMessage(error: Throwable): String {
        val message = generateSequence(error) { it.cause }
            .joinToString(" ") { it.message.orEmpty() }
            .lowercase()
        return when {
            "bitshare_instagram_story_requires_session" in message ->
                "Esta historia requiere la sesión privada de Instagram. " +
                    "Bit-Share no copia cookies ni credenciales de otras " +
                    "aplicaciones."
            "bitshare_meta_story_not_supported" in message ->
                "Esta historia no se puede descargar: el motor de descarga " +
                    "no la admite, sin importar la sesión."
            "bitshare_threads_public_video_not_found" in message ->
                "La publicación de Threads no contiene un vídeo público."
            "bitshare_threads_post_not_found" in message ||
                "bitshare_threads_invalid_redirect" in message ->
                "El enlace compartido de Threads ya no dirige a una publicación."
            "impersonat" in message || "http error 410" in message ->
                "Este sitio exige una conexión de navegador que esta " +
                    "versión Android aún no puede reproducir."
            "unsupported url" in message ->
                "Este sitio no ofrece una descarga compatible para ese enlace."
            "no video formats" in message || "requested format" in message ->
                "Este sitio no ofrece un vídeo descargable para ese enlace."
            "video unavailable" in message ->
                "El vídeo ya no está disponible públicamente."
            "login" in message || "cookies" in message ->
                "Este contenido necesita una sesión. Inicia sesión en Bit-Share " +
                    "para continuar."
            "private" in message -> "El contenido no está disponible públicamente."
            "ssl" in message || "network" in message || "connection" in message ->
                "La conexión segura se interrumpió. Inténtalo de nuevo."
            else -> "No se pudo descargar este contenido público."
        }
    }

    private fun diagnosticCode(error: Throwable): String {
        return generateSequence(error) { it.cause }
            .map {
                val detail = sanitizedDiagnostic(it.message)
                if (detail.isBlank()) {
                    it.javaClass.simpleName
                } else {
                    "${it.javaClass.simpleName}($detail)"
                }
            }
            .filter { it.isNotBlank() }
            .take(4)
            .joinToString(":")
            .ifBlank { "UnknownFailure" }
    }

    private fun sanitizedDiagnostic(rawMessage: String?): String {
        return rawMessage
            .orEmpty()
            .replace(Regex("""https?://\S+""", RegexOption.IGNORE_CASE), "<url>")
            .replace(
                Regex(
                    """(?i)(authorization|cookie|token)[=:][^\s]+""",
                ),
                "$1=<redacted>",
            )
            .take(1_000)
    }

    private companion object {
        const val LOG_TAG = "BitShareDownload"
        const val PREFERENCES_NAME = "bitshare_preferences"
        const val COMPLETED_DOWNLOADS_KEY = "completed_downloads"
        const val STORAGE_SAFETY_BYTES = 16 * 1024 * 1024L

    }

    private data class FormatInfo(
        val audioCodec: String?,
        val videoCodec: String?,
        val height: Int,
        val fileSize: Long,
        val fileSizeApproximate: Long,
        val audioBitrate: Double,
        val totalBitrate: Double,
    )
}
