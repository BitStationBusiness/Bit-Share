package com.bitstation.bitshare.bridge

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import com.bitstation.bitshare.auth.LoginSessionActivity
import com.bitstation.bitshare.auth.ProviderLogin
import com.bitstation.bitshare.download.DownloadCoordinator
import com.bitstation.bitshare.share.ShareIntentParser
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File

class BitSharePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.NewIntentListener,
    PluginRegistry.ActivityResultListener {
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var initialPayload: Map<String, Any?>? = null
    private var downloadCoordinator: DownloadCoordinator? = null
    private var appContext: Context? = null
    private var pendingLoginResult: MethodChannel.Result? = null
    private var pendingResolveResult: MethodChannel.Result? = null
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
            "updateCacheDir" -> {
                val context = appContext
                if (context == null) {
                    result.error("context_unavailable", "El motor no está listo.", null)
                    return
                }
                val dir = File(context.cacheDir, "update")
                dir.mkdirs()
                result.success(dir.absolutePath)
            }
            "installApk" -> {
                val activity = activityBinding?.activity
                val path = call.argument<String>("path")
                if (activity == null || path.isNullOrBlank()) {
                    result.error(
                        "activity_unavailable",
                        "No se pudo iniciar la instalación.",
                        null,
                    )
                    return
                }
                val apkFile = File(path)
                if (!apkFile.exists()) {
                    result.error("file_missing", "No se encontró el archivo descargado.", null)
                    return
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    !activity.packageManager.canRequestPackageInstalls()
                ) {
                    try {
                        activity.startActivity(
                            Intent(
                                android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:${activity.packageName}"),
                            ),
                        )
                    } catch (_: Throwable) {
                        // Fall through: the error below still tells the user what to do.
                    }
                    result.error(
                        "install_permission_required",
                        "Bit-Share necesita permiso para instalar apps desconocidas.",
                        null,
                    )
                    return
                }
                try {
                    val apkUri = FileProvider.getUriForFile(
                        activity,
                        "${activity.packageName}.fileprovider",
                        apkFile,
                    )
                    activity.startActivity(
                        Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(apkUri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        },
                    )
                    result.success(true)
                } catch (_: Throwable) {
                    result.error(
                        "installer_unavailable",
                        "No se pudo abrir el instalador de Android.",
                        null,
                    )
                }
            }
            "openLoginSession" -> {
                val activity = activityBinding?.activity
                val providerId = call.argument<String>("providerId")
                val target = providerId?.let(ProviderLogin::forProvider)
                if (activity == null || providerId == null || target == null) {
                    result.error(
                        "unsupported_provider",
                        "Este sitio no admite iniciar sesión desde Bit-Share.",
                        null,
                    )
                    return
                }
                if (pendingLoginResult != null) {
                    result.error(
                        "login_in_progress",
                        "Ya hay un inicio de sesión en curso.",
                        null,
                    )
                    return
                }
                pendingLoginResult = result
                activity.startActivityForResult(
                    Intent(activity, LoginSessionActivity::class.java).apply {
                        putExtra(LoginSessionActivity.EXTRA_PROVIDER_ID, providerId)
                        putExtra(LoginSessionActivity.EXTRA_LOGIN_URL, target.loginUrl)
                        putStringArrayListExtra(
                            LoginSessionActivity.EXTRA_COOKIE_URLS,
                            ArrayList(target.cookieUrls),
                        )
                    },
                    LOGIN_REQUEST_CODE,
                )
            }
            "resolveShareLink" -> {
                val activity = activityBinding?.activity
                val url = call.argument<String>("url")
                if (activity == null || url.isNullOrBlank()) {
                    result.error("invalid_url", "No se recibió un enlace.", null)
                    return
                }
                if (pendingResolveResult != null) {
                    result.error(
                        "resolve_in_progress",
                        "Ya hay una resolución de enlace en curso.",
                        null,
                    )
                    return
                }
                pendingResolveResult = result
                activity.startActivityForResult(
                    Intent(activity, LoginSessionActivity::class.java).apply {
                        putExtra(LoginSessionActivity.EXTRA_RESOLVE_URL, url)
                    },
                    RESOLVE_REQUEST_CODE,
                )
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
        binding.addActivityResultListener(this)
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

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        when (requestCode) {
            LOGIN_REQUEST_CODE -> {
                pendingLoginResult?.success(resultCode == Activity.RESULT_OK)
                pendingLoginResult = null
                return true
            }
            RESOLVE_REQUEST_CODE -> {
                val resolved = data?.getStringExtra(
                    LoginSessionActivity.EXTRA_RESOLVED_URL,
                )
                pendingResolveResult?.success(
                    resolved.takeIf { resultCode == Activity.RESULT_OK },
                )
                pendingResolveResult = null
                return true
            }
            else -> return false
        }
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
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        pendingLoginResult?.error(
            "activity_unavailable",
            "Se interrumpió el inicio de sesión.",
            null,
        )
        pendingLoginResult = null
        pendingResolveResult?.error(
            "activity_unavailable",
            "Se interrumpió la resolución del enlace.",
            null,
        )
        pendingResolveResult = null
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
        const val LOGIN_REQUEST_CODE = 4210
        const val RESOLVE_REQUEST_CODE = 4211
    }
}
