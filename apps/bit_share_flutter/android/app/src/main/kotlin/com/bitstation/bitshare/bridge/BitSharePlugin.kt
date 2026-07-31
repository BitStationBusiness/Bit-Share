package com.bitstation.bitshare.bridge

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.bitstation.bitshare.download.DownloadCoordinator
import com.bitstation.bitshare.share.ShareIntentParser
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

class BitSharePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.NewIntentListener {
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var initialPayload: Map<String, Any?>? = null
    private var downloadCoordinator: DownloadCoordinator? = null
    private var appContext: Context? = null
    private val mainHandler = Handler(Looper.getMainLooper())

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
        downloadCoordinator = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initializeEngine" -> result.success(null)
            "getInitialSharePayload" -> result.success(initialPayload)
            "inspectSharePayload" -> {
                val requestedId = call.argument<String>("payloadId")
                result.success(initialPayload?.takeIf { it["id"] == requestedId })
            }
            "inspectUrl" -> {
                val url = call.argument<String>("url")
                if (url.isNullOrBlank()) {
                    result.error("invalid_url", "No se recibió un enlace.", null)
                    return
                }
                coordinator().inspect(
                    url,
                    onSuccess = { inspection ->
                        mainHandler.post { result.success(inspection) }
                    },
                    onError = { message ->
                        mainHandler.post {
                            result.error("inspection_failed", message, null)
                        }
                    },
                )
            }
            "startDownload" -> {
                val url = call.argument<String>("url")
                if (url.isNullOrBlank()) {
                    result.error("invalid_url", "No se recibió un enlace.", null)
                    return
                }
                try {
                    val taskId = coordinator().start(
                        rawUrl = url,
                        mode = call.argument<String>("mode") ?: "video",
                        height = call.argument<Int>("height"),
                        estimatedSize = call.argument<Number>("estimatedBytes")?.toLong(),
                    )
                    result.success(mapOf("taskId" to taskId))
                } catch (error: IllegalArgumentException) {
                    result.error("unsupported_provider", error.message, null)
                }
            }
            "cancelDownload" -> {
                val taskId = call.argument<String>("taskId")
                result.success(
                    !taskId.isNullOrBlank() &&
                        coordinator().cancel(taskId),
                )
            }
            "shareResult" -> {
                val taskId = call.argument<String>("taskId")
                val activity = activityBinding?.activity
                result.success(
                    !taskId.isNullOrBlank() &&
                        activity != null &&
                        coordinator().share(activity, taskId),
                )
            }
            "openDonationPage" -> {
                val activity = activityBinding?.activity
                if (activity == null) {
                    result.error(
                        "activity_unavailable",
                        "No se pudo abrir el navegador.",
                        null,
                    )
                    return
                }
                try {
                    activity.startActivity(
                        Intent(
                            Intent.ACTION_VIEW,
                            Uri.parse(DONATION_URL),
                        ).addCategory(Intent.CATEGORY_BROWSABLE),
                    )
                    result.success(true)
                } catch (_: Throwable) {
                    result.error(
                        "browser_unavailable",
                        "No hay un navegador disponible.",
                        null,
                    )
                }
            }
            "retryDownload",
            "publishToMediaStore",
            "checkComponentUpdates",
            -> result.error(
                "checkpoint_not_available",
                "Esta operación se implementará en un checkpoint posterior.",
                null,
            )
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        eventSink = sink
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        capture(binding.activity, binding.activity.intent, emit = false)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    override fun onNewIntent(intent: Intent): Boolean {
        val activity = activityBinding?.activity ?: return false
        return capture(activity, intent, emit = true)
    }

    private fun capture(activity: Activity, intent: Intent?, emit: Boolean): Boolean {
        val payload = ShareIntentParser.parse(intent, activity.referrer?.host) ?: return false
        initialPayload = payload
        if (emit) {
            eventSink?.success(mapOf("type" to "shareReceived", "payload" to payload))
        }
        return true
    }

    private fun detachActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }

    private fun coordinator(): DownloadCoordinator {
        return downloadCoordinator ?: DownloadCoordinator(
            requireNotNull(appContext) { "Plugin no conectado al motor Flutter." },
        ) { event ->
            mainHandler.post { eventSink?.success(event) }
        }.also { downloadCoordinator = it }
    }

    private companion object {
        const val METHODS_CHANNEL = "bitshare/methods"
        const val EVENTS_CHANNEL = "bitshare/events"
        const val DONATION_URL = "https://ko-fi.com/bitstation"
    }
}
