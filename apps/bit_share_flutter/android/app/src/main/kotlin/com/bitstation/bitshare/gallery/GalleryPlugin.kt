package com.bitstation.bitshare.gallery

import android.app.Activity
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import com.bitstation.bitshare.media.FfmpegTools
import com.bitstation.bitshare.media.MediaStoreRepository
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.File
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Backs the `bitshare/gallery` channel Dart already calls into
 * (`AndroidMediaLibrary`/`AndroidMediaEditor`). Reads/writes are scoped to the
 * `Bit-Share` album [MediaStoreRepository] publishes downloads into, and
 * exports run the same bundled ffmpeg binary [FfmpegTools] hands to yt-dlp.
 */
class GalleryPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware {
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var appContext: Context? = null
    private var activity: Activity? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private var activeExport: Process? = null
    private val exportCancelled = AtomicBoolean(false)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, METHODS_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        events = EventChannel(binding.binaryMessenger, EVENTS_CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        methods = null
        events = null
        eventSink = null
        appContext = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        eventSink = sink
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = appContext
        if (context == null) {
            result.error("context_unavailable", "El motor no está listo.", null)
            return
        }
        when (call.method) {
            "list" -> executor.execute {
                runCatching { listItems(context) }
                    .onSuccess { items -> mainHandler.post { result.success(items) } }
                    .onFailure { error ->
                        mainHandler.post {
                            result.error(
                                "list_failed",
                                error.message ?: "No se pudo leer la galería.",
                                null,
                            )
                        }
                    }
            }
            "requestAccess" -> result.success(true)
            "thumbnail" -> {
                val id = call.argument<String>("id")
                if (id == null) {
                    result.error("invalid_id", "Falta el identificador.", null)
                    return
                }
                executor.execute {
                    val path = runCatching { thumbnailFor(context, id) }.getOrNull()
                    mainHandler.post { result.success(path) }
                }
            }
            "delete" -> {
                val ids = (call.argument<List<*>>("ids") ?: emptyList<Any>())
                    .mapNotNull { it as? String }
                executor.execute {
                    val deleted = deleteItems(context, ids)
                    mainHandler.post { result.success(deleted) }
                }
            }
            "share" -> {
                val id = call.argument<String>("id")
                val activeActivity = activity
                if (id == null || activeActivity == null) {
                    result.success(false)
                    return
                }
                result.success(shareItem(context, activeActivity, id))
            }
            "probe" -> {
                val id = call.argument<String>("id")
                if (id == null) {
                    result.error("invalid_id", "Falta el identificador.", null)
                    return
                }
                executor.execute {
                    runCatching { probeItem(context, id) }
                        .onSuccess { probed -> mainHandler.post { result.success(probed) } }
                        .onFailure { error ->
                            mainHandler.post {
                                result.error(
                                    "probe_failed",
                                    error.message ?: "No se pudo leer la información del archivo.",
                                    null,
                                )
                            }
                        }
                }
            }
            "export" -> {
                val arguments = call.arguments as? Map<*, *>
                if (arguments == null) {
                    result.error("invalid_arguments", "Faltan datos de la edición.", null)
                    return
                }
                executor.execute { runExport(context, arguments, result) }
            }
            "cancelExport" -> {
                exportCancelled.set(true)
                activeExport?.destroy()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ---- Listing --------------------------------------------------------

    private fun listItems(context: Context): Map<String, Any?> {
        val items = mutableListOf<Map<String, Any?>>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            items += queryCollection(
                resolver,
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
                hasDuration = true,
                hasDimensions = true,
            )
            items += queryCollection(
                resolver,
                MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
                hasDuration = true,
                hasDimensions = false,
            )
            items += queryCollection(
                resolver,
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
                hasDuration = false,
                hasDimensions = true,
            )
        } else {
            // Pre-Q installs never had scoped-storage MediaStore access, so
            // MediaStoreRepository.publish() writes straight into the app's
            // own external-files "Downloads" folder instead. That is the
            // only place Bit-Share's own media can live on those devices.
            items += legacyFilesFallback(context)
        }
        items.sortByDescending { (it["modifiedAtMs"] as? Long) ?: 0L }
        return mapOf("items" to items, "accessRestricted" to false)
    }

    private fun queryCollection(
        resolver: ContentResolver,
        collection: Uri,
        hasDuration: Boolean,
        hasDimensions: Boolean,
    ): List<Map<String, Any?>> {
        val projection = mutableListOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.DATE_MODIFIED,
        )
        if (hasDuration) projection += MediaStore.MediaColumns.DURATION
        if (hasDimensions) {
            projection += MediaStore.MediaColumns.WIDTH
            projection += MediaStore.MediaColumns.HEIGHT
        }
        val selection = "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?"
        val selectionArgs = arrayOf("%Bit-Share%")
        val results = mutableListOf<Map<String, Any?>>()
        resolver.query(
            collection,
            projection.toTypedArray(),
            selection,
            selectionArgs,
            "${MediaStore.MediaColumns.DATE_MODIFIED} DESC",
        )?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val nameCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            val mimeCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
            val modifiedCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
            val durationCol = if (hasDuration) {
                cursor.getColumnIndex(MediaStore.MediaColumns.DURATION)
            } else {
                -1
            }
            val widthCol = if (hasDimensions) {
                cursor.getColumnIndex(MediaStore.MediaColumns.WIDTH)
            } else {
                -1
            }
            val heightCol = if (hasDimensions) {
                cursor.getColumnIndex(MediaStore.MediaColumns.HEIGHT)
            } else {
                -1
            }
            while (cursor.moveToNext()) {
                val uri = ContentUris.withAppendedId(collection, cursor.getLong(idCol))
                results += mapOf(
                    "id" to uri.toString(),
                    "uri" to uri.toString(),
                    "path" to null,
                    "name" to cursor.getString(nameCol),
                    "mimeType" to (cursor.getString(mimeCol) ?: ""),
                    "sizeBytes" to cursor.getLong(sizeCol),
                    "durationMs" to if (durationCol >= 0) cursor.getLong(durationCol) else null,
                    "modifiedAtMs" to cursor.getLong(modifiedCol) * 1000L,
                    "width" to if (widthCol >= 0) cursor.getInt(widthCol) else null,
                    "height" to if (heightCol >= 0) cursor.getInt(heightCol) else null,
                )
            }
        }
        return results
    }

    private fun legacyFilesFallback(context: Context): List<Map<String, Any?>> {
        val directory = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?: return emptyList()
        val files = directory.listFiles()?.filter { it.isFile } ?: return emptyList()
        return files.map { file ->
            val uri = Uri.fromFile(file)
            mapOf(
                "id" to uri.toString(),
                "uri" to uri.toString(),
                "path" to file.absolutePath,
                "name" to file.name,
                "mimeType" to (mimeTypeForExtension(file.extension) ?: ""),
                "sizeBytes" to file.length(),
                "durationMs" to null,
                "modifiedAtMs" to file.lastModified(),
                "width" to null,
                "height" to null,
            )
        }
    }

    private fun queryRow(context: Context, uri: Uri): Map<String, Any?>? {
        if (uri.scheme == "file") {
            val file = uri.path?.let(::File) ?: return null
            if (!file.isFile) return null
            return mapOf(
                "id" to uri.toString(),
                "uri" to uri.toString(),
                "name" to file.name,
                "mimeType" to (mimeTypeForExtension(file.extension) ?: ""),
                "sizeBytes" to file.length(),
                "modifiedAtMs" to file.lastModified(),
            )
        }
        val projection = arrayOf(
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.DATE_MODIFIED,
        )
        context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            if (!cursor.moveToFirst()) return null
            return mapOf(
                "id" to uri.toString(),
                "uri" to uri.toString(),
                "name" to cursor.getString(0),
                "mimeType" to (cursor.getString(2) ?: ""),
                "sizeBytes" to cursor.getLong(1),
                "modifiedAtMs" to cursor.getLong(3) * 1000L,
            )
        }
        return null
    }

    // ---- Delete / share ---------------------------------------------------

    private fun deleteItems(context: Context, ids: List<String>): Int {
        var deleted = 0
        ids.forEach { id ->
            try {
                val uri = Uri.parse(id)
                if (uri.scheme == "file") {
                    val path = uri.path
                    if (path != null && File(path).delete()) deleted++
                } else if (context.contentResolver.delete(uri, null, null) > 0) {
                    deleted++
                }
            } catch (_: Exception) {
                // Skip: the item may already be gone.
            }
        }
        return deleted
    }

    private fun shareItem(context: Context, activity: Activity, id: String): Boolean {
        return try {
            val original = Uri.parse(id)
            val row = queryRow(context, original)
            val mimeType = row?.get("mimeType") as? String
                ?: context.contentResolver.getType(original)
                ?: "*/*"
            val shareUri = if (original.scheme == "file") {
                val path = original.path ?: return false
                FileProvider.getUriForFile(
                    context,
                    "${context.packageName}.fileprovider",
                    File(path),
                )
            } else {
                original
            }
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, shareUri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(Intent.createChooser(intent, "Compartir con"))
            true
        } catch (_: Exception) {
            false
        }
    }

    // ---- Thumbnails ---------------------------------------------------

    private fun thumbnailFor(context: Context, id: String): String? {
        val uri = Uri.parse(id)
        val cacheDir = File(context.cacheDir, "gallery-thumbnails").apply { mkdirs() }
        val digest = sha1(id)
        val target = File(cacheDir, "$digest.jpg")
        if (target.isFile && target.length() > 0) return target.absolutePath

        val mimeType = queryRow(context, uri)?.get("mimeType") as? String
            ?: context.contentResolver.getType(uri)
            ?: ""
        val bitmap: Bitmap = when {
            mimeType.startsWith("video/") -> videoFrame(context, uri)
            mimeType.startsWith("audio/") -> embeddedArt(context, uri)
            mimeType.startsWith("image/") -> downsampledImage(context, uri)
            else -> null
        } ?: return null

        return try {
            FileOutputStream(target).use { output ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 85, output)
            }
            target.absolutePath
        } catch (_: Exception) {
            null
        } finally {
            bitmap.recycle()
        }
    }

    private fun videoFrame(context: Context, uri: Uri): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(context, uri)
            val durationMs = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
            // A tenth of the way in avoids the black/logo frame many clips
            // open on, matching the same heuristic the Windows library uses.
            val frameTimeUs = (durationMs / 10).coerceIn(0L, 3000L) * 1000L
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                retriever.getScaledFrameAtTime(
                    frameTimeUs,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                    640,
                    640,
                ) ?: retriever.frameAtTime
            } else {
                @Suppress("DEPRECATION")
                retriever.getFrameAtTime(frameTimeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            }
        } catch (_: Exception) {
            null
        } finally {
            retriever.release()
        }
    }

    private fun embeddedArt(context: Context, uri: Uri): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(context, uri)
            val art = retriever.embeddedPicture ?: return null
            BitmapFactory.decodeByteArray(art, 0, art.size)
        } catch (_: Exception) {
            null
        } finally {
            retriever.release()
        }
    }

    private fun downsampledImage(context: Context, uri: Uri): Bitmap? {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            context.contentResolver.openInputStream(uri)?.use { input ->
                BitmapFactory.decodeStream(input, null, bounds)
            }
            val sample = sampleSizeFor(bounds.outWidth, bounds.outHeight, 640, 640)
            context.contentResolver.openInputStream(uri)?.use { input ->
                BitmapFactory.decodeStream(
                    input,
                    null,
                    BitmapFactory.Options().apply { inSampleSize = sample },
                )
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun sampleSizeFor(width: Int, height: Int, reqWidth: Int, reqHeight: Int): Int {
        var inSampleSize = 1
        if (height > reqHeight || width > reqWidth) {
            var halfHeight = height / 2
            var halfWidth = width / 2
            while (halfHeight / inSampleSize >= reqHeight && halfWidth / inSampleSize >= reqWidth) {
                inSampleSize *= 2
            }
        }
        return inSampleSize
    }

    // ---- Probe ----------------------------------------------------------

    private fun probeItem(context: Context, id: String): Map<String, Any?> {
        val uri = Uri.parse(id)
        val base = queryRow(context, uri) ?: mapOf("id" to id, "uri" to id)
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(context, uri)
            val durationMs = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()
            val rawWidth = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                ?.toIntOrNull()
            val rawHeight = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                ?.toIntOrNull()
            val rotation = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                ?.toIntOrNull() ?: 0
            val swapped = rotation == 90 || rotation == 270
            base + mapOf(
                "durationMs" to durationMs,
                "width" to if (swapped) rawHeight else rawWidth,
                "height" to if (swapped) rawWidth else rawHeight,
            )
        } catch (_: Exception) {
            base
        } finally {
            retriever.release()
        }
    }

    // ---- Export -----------------------------------------------------------

    private fun runExport(context: Context, arguments: Map<*, *>, result: MethodChannel.Result) {
        exportCancelled.set(false)
        val id = arguments["id"] as? String
        val uri = id?.let(Uri::parse)
        if (uri == null) {
            mainHandler.post { result.error("invalid_id", "Falta el identificador.", null) }
            return
        }
        val startMs = (arguments["startMs"] as? Number)?.toLong() ?: 0L
        val endMs = (arguments["endMs"] as? Number)?.toLong() ?: 0L
        val sourceDurationMs = (arguments["sourceDurationMs"] as? Number)?.toLong() ?: 0L
        val mute = arguments["mute"] as? Boolean ?: false
        val volume = ((arguments["volume"] as? Number)?.toDouble() ?: 1.0)
            .coerceIn(0.0, 2.0)
        val rotationDegrees = (arguments["rotationDegrees"] as? Number)?.toInt() ?: 0
        val speed = (arguments["speed"] as? Number)?.toDouble() ?: 1.0
        val longestSide = (arguments["longestSide"] as? Number)?.toInt()

        val row = queryRow(context, uri)
        val displayName = row?.get("name") as? String ?: "Bit-Share"
        val mimeType = row?.get("mimeType") as? String
            ?: context.contentResolver.getType(uri)
            ?: ""
        val isVideo = mimeType.startsWith("video/")

        var width: Int? = null
        var height: Int? = null
        if (isVideo) {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(context, uri)
                width = retriever
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                    ?.toIntOrNull()
                height = retriever
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                    ?.toIntOrNull()
            } catch (_: Exception) {
                // Missing dimensions only disable rescale math below.
            } finally {
                retriever.release()
            }
        }

        val workDir = File(context.cacheDir, "gallery-export").apply { mkdirs() }
        val baseName = displayName.substringBeforeLast('.', displayName)
        val sourceExtension = displayName.substringAfterLast('.', "")
        val originalExtension = sourceExtension.ifBlank { if (isVideo) "mp4" else "m4a" }
        // Bit-Share only ever hands back MP4 video and MP3 audio, whatever
        // the source happened to be. An edited clip has to open on the same
        // players the original did, and those two are the pair every phone,
        // desktop and messaging app plays without a codec pack.
        val outputExtension = if (isVideo) "mp4" else "mp3"

        val inputFile = File(workDir, "input-${System.nanoTime()}.$originalExtension")
        val outputFile = uniqueOutputFile(workDir, baseName, outputExtension)

        try {
            context.contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(inputFile).use { output -> input.copyTo(output) }
            } ?: throw IllegalStateException("No se pudo leer el archivo original.")

            val plan = buildExportPlan(
                inputPath = inputFile.absolutePath,
                outputPath = outputFile.absolutePath,
                startMs = startMs,
                endMs = endMs,
                sourceDurationMs = sourceDurationMs,
                mute = mute,
                volume = volume,
                rotationDegrees = rotationDegrees,
                speed = speed,
                longestSide = longestSide,
                isVideo = isVideo,
                width = width,
                height = height,
                outputExtension = outputExtension,
                sourceExtension = originalExtension,
            )

            // ffmpeg here is `libffmpeg.so`, a dynamically linked executable
            // whose libav* dependencies ship inside youtubedl-android's
            // package archives. FfmpegTools.start unpacks them and puts them
            // on LD_LIBRARY_PATH; a bare ProcessBuilder cannot, and the
            // process would die before reading its first argument.
            val process = FfmpegTools.start(context, plan.arguments)
            activeExport = process

            // stderr has to be drained on its own thread. Left unread, a
            // filled pipe buffer blocks ffmpeg mid-encode; read afterwards,
            // the reason a failed export failed is already gone.
            val diagnostics = StringBuilder()
            val stderrDrain = Thread {
                BufferedReader(InputStreamReader(process.errorStream)).use { reader ->
                    reader.forEachLine { line ->
                        if (diagnostics.length < 8192) diagnostics.appendLine(line)
                    }
                }
            }.apply {
                isDaemon = true
                start()
            }

            BufferedReader(InputStreamReader(process.inputStream)).use { reader ->
                var line: String?
                while (reader.readLine().also { line = it } != null) {
                    val progress = progressFrom(line ?: continue, plan.expectedDurationMs)
                    if (progress != null) {
                        val sink = eventSink
                        mainHandler.post {
                            sink?.success(mapOf("type" to "editProgress", "progress" to progress))
                        }
                    }
                }
            }
            val exitCode = process.waitFor()
            stderrDrain.join(2_000)
            activeExport = null

            if (exportCancelled.get()) {
                outputFile.delete()
                mainHandler.post { result.error("edit_cancelled", "Edición cancelada.", null) }
                return
            }
            if (exitCode != 0 || !outputFile.isFile || outputFile.length() == 0L) {
                outputFile.delete()
                val reason = friendlyExportFailure(diagnostics.toString())
                mainHandler.post { result.error("export_failed", reason, null) }
                return
            }

            val mediaStoreRepository = MediaStoreRepository(context)
            val published = mediaStoreRepository.publish(outputFile)
            val exportedSize = outputFile.length()
            mainHandler.post {
                result.success(
                    mapOf(
                        "id" to published.uri.toString(),
                        "uri" to published.uri.toString(),
                        "path" to null,
                        "name" to published.displayName,
                        "mimeType" to published.mimeType,
                        "sizeBytes" to exportedSize,
                        "durationMs" to plan.expectedDurationMs,
                        "modifiedAtMs" to System.currentTimeMillis(),
                        "width" to null,
                        "height" to null,
                    ),
                )
            }
        } catch (error: Exception) {
            mainHandler.post {
                result.error(
                    "export_failed",
                    error.message ?: "No se pudo procesar la edición.",
                    null,
                )
            }
        } finally {
            activeExport = null
            inputFile.delete()
        }
    }

    private data class ExportPlan(val arguments: List<String>, val expectedDurationMs: Long)

    /** Kotlin port of `buildFfmpegEditPlan` in `ffmpeg_plan.dart`, kept in
     * lockstep with it so an edit produces the same result on both platforms. */
    private fun buildExportPlan(
        inputPath: String,
        outputPath: String,
        startMs: Long,
        endMs: Long,
        sourceDurationMs: Long,
        mute: Boolean,
        volume: Double,
        rotationDegrees: Int,
        speed: Double,
        longestSide: Int?,
        isVideo: Boolean,
        width: Int?,
        height: Int?,
        outputExtension: String,
        sourceExtension: String,
    ): ExportPlan {
        val clampedStart = startMs.coerceAtLeast(0L)
        val clampedEnd = if (endMs > clampedStart) endMs else sourceDurationMs
        val selectionMs = (clampedEnd - clampedStart).coerceAtLeast(0L)
        val outputDurationMs = if (speed == 1.0) {
            selectionMs
        } else {
            (selectionMs / speed).toLong()
        }
        val isTrimmed = clampedStart > 40L || (sourceDurationMs - clampedEnd) > 40L
        val isRotated = rotationDegrees != 0
        val isSpeedAdjusted = speed != 1.0
        val isVolumeAdjusted = volume != 1.0
        val scaled = scaledSize(width, height, longestSide)
        val isRescaled = scaled != null
        // Copying the video track verbatim is only safe when it already
        // lives in an MP4-family container: a VP9 or AV1 track pulled out of
        // a .webm has no MP4 tag, and `-c:v copy` fails outright with
        // "codec not currently supported in container". Re-encoding is
        // slower but always produces a file.
        val streamCopy = isVideo && mute && !isTrimmed && !isRotated &&
            !isSpeedAdjusted && !isVolumeAdjusted && !isRescaled &&
            sourceExtension.lowercase() in MP4_CONTAINERS

        val arguments = mutableListOf(
            "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
            "-progress", "pipe:1", "-nostats",
        )
        if (clampedStart > 0L) arguments += listOf("-ss", formatTimestamp(clampedStart))
        if (clampedEnd < sourceDurationMs) {
            arguments += listOf("-t", formatTimestamp(selectionMs))
        }
        arguments += listOf("-i", inputPath)

        val keepsAudio = !(isVideo && mute)
        if (isVideo) {
            arguments += listOf("-map", "0:v:0")
            if (keepsAudio) arguments += listOf("-map", "0:a:0?")
            val filters = videoFilters(scaled, rotationDegrees, isSpeedAdjusted, speed)
            if (streamCopy) {
                arguments += listOf("-c:v", "copy")
            } else {
                if (filters.isNotEmpty()) arguments += listOf("-vf", filters.joinToString(","))
                arguments += listOf(
                    "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
                )
            }
            if (!keepsAudio) {
                arguments += "-an"
            } else if (streamCopy) {
                arguments += listOf("-c:a", "copy")
            } else {
                val audioFilter = audioFilter(isSpeedAdjusted, speed, isVolumeAdjusted, volume)
                if (audioFilter != null) arguments += listOf("-af", audioFilter)
                arguments += listOf("-c:a", "aac", "-b:a", "160k")
            }
            arguments += listOf("-movflags", "+faststart")
        } else {
            arguments += listOf("-vn", "-map", "0:a:0")
            val audioFilter = audioFilter(isSpeedAdjusted, speed, isVolumeAdjusted, volume)
            if (audioFilter != null) arguments += listOf("-af", audioFilter)
            if (outputExtension == "mp3") {
                arguments += listOf("-c:a", "libmp3lame", "-q:a", "2")
            } else {
                arguments += listOf("-c:a", "aac", "-b:a", "192k")
            }
        }
        arguments += outputPath
        return ExportPlan(arguments, outputDurationMs.coerceAtLeast(0L))
    }

    private fun scaledSize(width: Int?, height: Int?, longestSide: Int?): Pair<Int, Int>? {
        if (width == null || height == null || width <= 0 || height <= 0 || longestSide == null) {
            return null
        }
        val longest = maxOf(width, height)
        if (longest <= longestSide) return null
        val factor = longestSide.toDouble() / longest
        return evenDimension(width * factor) to evenDimension(height * factor)
    }

    private fun evenDimension(value: Double): Int {
        val rounded = Math.round(value).toInt()
        val even = if (rounded % 2 == 0) rounded else rounded + 1
        return even.coerceAtLeast(2)
    }

    private fun videoFilters(
        scaled: Pair<Int, Int>?,
        rotationDegrees: Int,
        isSpeedAdjusted: Boolean,
        speed: Double,
    ): List<String> {
        val filters = mutableListOf<String>()
        if (scaled != null) filters += "scale=${scaled.first}:${scaled.second}"
        when (rotationDegrees) {
            90 -> filters += "transpose=1"
            270 -> filters += "transpose=2"
            180 -> {
                filters += "transpose=1"
                filters += "transpose=1"
            }
        }
        if (isSpeedAdjusted) filters += "setpts=PTS/${formatNumber(speed)}"
        return filters
    }

    /** Keep the Android plan byte-for-byte equivalent in intent to Dart's
     * `buildFfmpegEditPlan`: one -af chain preserves both speed and volume. */
    private fun audioFilter(
        isSpeedAdjusted: Boolean,
        speed: Double,
        isVolumeAdjusted: Boolean,
        volume: Double,
    ): String? {
        val filters = mutableListOf<String>()
        if (isSpeedAdjusted) filters += "atempo=${formatNumber(speed)}"
        if (isVolumeAdjusted) filters += "volume=${formatNumber(volume)}"
        return filters.takeIf { it.isNotEmpty() }?.joinToString(",")
    }

    private fun formatNumber(value: Double): String {
        val text = "%.3f".format(value)
        return text.trimEnd('0').trimEnd('.')
    }

    private fun formatTimestamp(ms: Long): String {
        val clamped = ms.coerceAtLeast(0L)
        val hours = clamped / 3_600_000
        val minutes = (clamped / 60_000) % 60
        val seconds = (clamped / 1000) % 60
        val millis = clamped % 1000
        return "%02d:%02d:%02d.%03d".format(hours, minutes, seconds, millis)
    }

    private fun progressFrom(line: String, expectedDurationMs: Long): Double? {
        if (expectedDurationMs <= 0L) return null
        val separator = line.indexOf('=')
        if (separator <= 0) return null
        val key = line.substring(0, separator).trim()
        if (key != "out_time") return null
        val value = line.substring(separator + 1).trim()
        val match = TIMESTAMP_PATTERN.find(value) ?: return null
        val hours = match.groupValues[1].toLong()
        val minutes = match.groupValues[2].toLong()
        val seconds = match.groupValues[3].toLong()
        val fraction = match.groupValues.getOrNull(4).orEmpty()
        val millis = if (fraction.isEmpty()) 0L else ("0.$fraction".toDouble() * 1000).toLong()
        val positionMs = hours * 3_600_000 + minutes * 60_000 + seconds * 1000 + millis
        return (positionMs.toDouble() / expectedDurationMs).coerceIn(0.0, 1.0)
    }

    /** Edits are saved alongside the original rather than over it, mirroring
     * the Windows editor's `_uniqueOutputPath`. */
    private fun uniqueOutputFile(dir: File, baseName: String, extension: String): File {
        val sanitizedBase = sanitizeFileName(baseName)
        var candidate = File(dir, "$sanitizedBase (editado).$extension")
        var attempt = 2
        while (candidate.exists()) {
            candidate = File(dir, "$sanitizedBase (editado $attempt).$extension")
            attempt++
        }
        return candidate
    }

    private fun sanitizeFileName(name: String): String {
        val cleaned = name.replace(Regex("[<>:\"/\\\\|?*\\x00-\\x1F]"), "_").trim()
        return cleaned.ifBlank { "Bit-Share" }
    }

    /** Turns ffmpeg's own stderr into something a user can act on, while
     * keeping the raw tail for the cases none of the patterns match. */
    private fun friendlyExportFailure(rawError: String): String {
        val error = rawError.lowercase()
        return when {
            error.isBlank() -> "No se pudo procesar la edición."
            "cannot link executable" in error ||
                ("library" in error && "not found" in error) ->
                "El motor multimedia no se pudo iniciar. Reinicia Bit-Share " +
                    "e inténtalo de nuevo."
            "no space left" in error ->
                "No hay espacio suficiente para guardar el archivo editado."
            "permission denied" in error ->
                "Android no permitió escribir el archivo editado."
            "invalid data" in error || "moov atom not found" in error ->
                "El archivo original está dañado y no se puede editar."
            "codec not currently supported in container" in error ->
                "El formato del archivo original no es compatible con MP4."
            else -> "No se pudo procesar la edición: " +
                rawError.trim().takeLast(180)
        }
    }

    private fun mimeTypeForExtension(extension: String): String? {
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension.lowercase())
    }

    private fun sha1(value: String): String {
        return MessageDigest.getInstance("SHA-1")
            .digest(value.toByteArray())
            .joinToString("") { "%02x".format(it) }
    }

    private companion object {
        const val METHODS_CHANNEL = "bitshare/gallery"
        const val EVENTS_CHANNEL = "bitshare/gallery/events"
        val TIMESTAMP_PATTERN = Regex("""^(\d+):([0-5]?\d):([0-5]?\d)(?:\.(\d+))?$""")
        val MP4_CONTAINERS = setOf("mp4", "m4v", "mov", "m4a")
    }
}
