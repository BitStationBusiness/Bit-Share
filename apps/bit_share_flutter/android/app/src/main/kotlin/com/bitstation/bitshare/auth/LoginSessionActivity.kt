package com.bitstation.bitshare.auth

import android.app.Activity
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import java.io.File

/**
 * A plain (non-Flutter) activity that hosts one real WebView, used two ways:
 *
 * - Login mode (EXTRA_LOGIN_URL): shows the provider's own login page. The
 *   user types their password into that page, not into anything Bit-Share
 *   renders — the WebView's JS/DOM owns the form and submits it straight to
 *   the provider over HTTPS, so this code never sees it. Tapping "Listo"
 *   only reads the *resulting* session cookies (CookieManager.getCookie),
 *   written to a private, per-provider file for DownloadCoordinator to hand
 *   to yt-dlp.
 *
 * - Resolve mode (EXTRA_RESOLVE_URL): silently loads a URL and waits for it
 *   to stop navigating, then returns wherever it landed. This exists because
 *   Facebook's `/share/<id>/` links resolve to their real content URL via a
 *   client-side redirect that only a real browser engine reliably follows —
 *   yt-dlp's own HTTP client gets reset attempting it directly (see
 *   DownloadCoordinator's use of this mode before inspect/download). Using
 *   the same CookieManager singleton as login mode means an already
 *   signed-in session carries over automatically, so a share link to a
 *   private post can resolve to the real (authenticated) content URL too.
 *
 *   When the resolved URL is itself a Facebook Story viewer page, resolve
 *   mode stays on it a little longer and watches outgoing requests for the
 *   story's actual video file on fbcdn.net (see shouldInterceptRequest
 *   below) — yt-dlp has no extractor for the Story *page*, but the raw CDN
 *   URL the player itself fetches is just an ordinary progressive video
 *   download once captured, the same trick bitshare_ytdlp.py already uses
 *   for Threads.
 *
 * Either way this mirrors the Windows client's "open your own browser, then
 * reuse that session" flow (see windows_download_backend_io.dart) as closely
 * as Android's sandboxing allows: an Android app cannot read another app's
 * (Chrome's) cookie jar, so the session has to be established inside a
 * WebView Bit-Share itself hosts instead.
 */
class LoginSessionActivity : Activity() {
    private lateinit var webView: WebView
    private var cookieUrls: List<String> = emptyList()
    private var providerId: String = ""
    private var resolving = false
    private var finished = false
    private val handler = Handler(Looper.getMainLooper())
    private var lastSeenUrl: String? = null
    private var stableTicks = 0
    private var capturedMediaUrl: String? = null
    private var capturedAudioUrl: String? = null
    private var lockedVideoId: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val resolveUrl = intent.getStringExtra(EXTRA_RESOLVE_URL)
        resolving = resolveUrl != null
        val startUrl: String

        if (resolving) {
            startUrl = resolveUrl!!
        } else {
            providerId = intent.getStringExtra(EXTRA_PROVIDER_ID).orEmpty()
            val loginUrl = intent.getStringExtra(EXTRA_LOGIN_URL)
            cookieUrls = intent.getStringArrayListExtra(EXTRA_COOKIE_URLS).orEmpty()
            if (providerId.isBlank() || loginUrl.isNullOrBlank() || cookieUrls.isEmpty()) {
                finish()
                return
            }
            startUrl = loginUrl
        }

        setContentView(buildLayout())
        configureWebView()
        webView.loadUrl(startUrl)

        if (resolving) {
            lastSeenUrl = startUrl
            // A stalled or infinitely-rerendering SPA must not hang the
            // share flow forever: fall back to whatever URL is current.
            handler.postDelayed({ finishResolved() }, RESOLVE_TIMEOUT_MS)
        }
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    override fun onBackPressed() {
        if (!resolving && webView.canGoBack()) {
            webView.goBack()
        } else {
            finishCancelled()
        }
    }

    private fun buildLayout(): View {
        val density = resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#0E0C13"))
        }

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), dp(10), dp(12), dp(10))
        }
        val closeButton = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            background = null
            setColorFilter(Color.parseColor("#E4E0EC"))
            contentDescription = "Cancelar"
            setOnClickListener { finishCancelled() }
        }
        val title = TextView(this).apply {
            text = if (resolving) "Resolviendo enlace…" else "Inicia sesión"
            setTextColor(Color.WHITE)
            textSize = 16f
            setPadding(dp(8), 0, dp(8), 0)
            layoutParams = LinearLayout.LayoutParams(
                0,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                1f,
            )
        }
        header.addView(closeButton)
        header.addView(title)
        if (!resolving) {
            header.addView(
                Button(this).apply {
                    text = "Listo"
                    setOnClickListener { finishWithSession() }
                },
            )
        }
        root.addView(header)

        val progressBar = ProgressBar(
            this,
            null,
            android.R.attr.progressBarStyleHorizontal,
        ).apply {
            max = 100
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(2),
            )
        }
        root.addView(progressBar)

        webView = WebView(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f,
            )
            webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView, url: String?) {
                    if (resolving) scheduleStabilityCheck()
                }

                // Observation only — always returns null so the request
                // proceeds exactly as the page intended. This just lets
                // Bit-Share notice the requests that matter (the story's
                // own video and audio track fetches) without acting as a
                // proxy.
                override fun shouldInterceptRequest(
                    view: WebView,
                    request: WebResourceRequest,
                ): WebResourceResponse? {
                    if (resolving) captureFacebookMediaRequest(request.url.toString())
                    return null
                }
            }
            webChromeClient = object : WebChromeClient() {
                override fun onProgressChanged(view: WebView, newProgress: Int) {
                    progressBar.progress = newProgress
                    progressBar.visibility =
                        if (newProgress >= 100) View.GONE else View.VISIBLE
                }
            }
        }
        root.addView(webView)

        if (!resolving) {
            root.addView(
                TextView(this).apply {
                    text = "Bit-Share no recibe tu contraseña. La sesión se " +
                        "consulta localmente y solo después de tocar “Listo”."
                    setTextColor(Color.parseColor("#9A93A8"))
                    textSize = 11f
                    setPadding(dp(16), dp(8), dp(16), dp(12))
                },
            )
        }

        return root
    }

    private fun configureWebView() {
        val settings = webView.settings
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.databaseEnabled = true
        // Providers gate their real (non-mobile-app-redirect) login form —
        // and Facebook's share-link redirect logic — behind a
        // desktop-looking UA on some paths.
        settings.userAgentString = DESKTOP_USER_AGENT
        // WebView blocks JS-initiated <video>.play() without a user gesture
        // by default. A Story page that can't autoplay never starts its
        // real video fetch — it only ever loads a tiny poster/preview clip
        // — so resolve mode (no user present to tap play) would otherwise
        // capture the wrong, much smaller file every time.
        settings.mediaPlaybackRequiresUserGesture = false

        val cookieManager = CookieManager.getInstance()
        cookieManager.setAcceptCookie(true)
        cookieManager.setAcceptThirdPartyCookies(webView, true)
    }

    /** Polls webView.url every 500ms; two consecutive identical reads means
     * the SPA's client-side routing has settled, not just that the initial
     * HTTP response finished loading. On a Story page specifically, the URL
     * settling doesn't mean the player has fetched its video yet, so those
     * keep polling a bit longer (bounded by STORY_EXTRA_TICKS, and by
     * RESOLVE_TIMEOUT_MS as the hard ceiling either way). */
    private fun scheduleStabilityCheck() {
        handler.postDelayed(
            {
                if (finished) return@postDelayed
                val current = webView.url
                if (current != null && current == lastSeenUrl) {
                    stableTicks++
                } else {
                    stableTicks = 0
                    lastSeenUrl = current
                }
                val waitingForStoryMedia = isFacebookStoryUrl(current) &&
                    (capturedMediaUrl == null || capturedAudioUrl == null)
                val readyToFinish = stableTicks >= 2 &&
                    (!waitingForStoryMedia || stableTicks >= STORY_EXTRA_TICKS)
                if (readyToFinish) {
                    finishResolved()
                } else {
                    scheduleStabilityCheck()
                }
            },
            STABILITY_POLL_MS,
        )
    }

    private fun looksLikeFacebookVideoUrl(url: String): Boolean {
        val host = Uri.parse(url).host?.lowercase() ?: return false
        if (!host.endsWith("fbcdn.net")) return false
        // `.mp4` alone, deliberately: poster/thumbnail requests on the same
        // CDN also carry an `efg=` parameter, so that alone over-matched
        // and picked up a ~100KB preview image instead of the real video.
        return url.substringBefore('?').endsWith(".mp4")
    }

    /** Facebook serves the Story's video and audio as two separate DASH
     * tracks, each fetched incrementally via `bytestart`/`byteend` query
     * params against an otherwise-stable per-track URL (not a standard HTTP
     * Range header — Facebook's own pseudo-range scheme). The `efg` param is
     * a base64 JSON blob carrying `vencode_tag` (contains "audio" for the
     * audio track) and `video_id`, which is used to ignore tracks belonging
     * to a *different* story the tray preloads next while this one is still
     * being captured. */
    private fun captureFacebookMediaRequest(url: String) {
        if (!looksLikeFacebookVideoUrl(url)) return
        val uri = Uri.parse(url)
        val efgRaw = uri.getQueryParameter("efg") ?: return
        val efg = runCatching {
            val decoded = android.util.Base64.decode(efgRaw, android.util.Base64.DEFAULT)
            org.json.JSONObject(String(decoded, Charsets.UTF_8))
        }.getOrNull() ?: return

        val videoId = efg.optString("video_id").takeIf { it.isNotBlank() }
        if (videoId != null) {
            if (lockedVideoId == null) lockedVideoId = videoId
            if (videoId != lockedVideoId) return
        }

        val fullResourceUrl = uri.buildUpon().clearQuery().apply {
            for (name in uri.queryParameterNames) {
                if (name == "bytestart" || name == "byteend") continue
                for (value in uri.getQueryParameters(name)) {
                    appendQueryParameter(name, value)
                }
            }
        }.build().toString()

        val tag = efg.optString("vencode_tag")
        if (tag.contains("audio", ignoreCase = true)) {
            capturedAudioUrl = fullResourceUrl
        } else {
            capturedMediaUrl = fullResourceUrl
        }
    }

    private fun isFacebookStoryUrl(url: String?): Boolean {
        if (url == null) return false
        val uri = Uri.parse(url)
        val host = uri.host?.lowercase() ?: return false
        return (host == "facebook.com" || host.endsWith(".facebook.com")) &&
            uri.path?.startsWith("/stories/") == true
    }

    private fun finishResolved() {
        if (finished) return
        finished = true
        setResult(
            RESULT_OK,
            android.content.Intent().apply {
                putExtra(EXTRA_RESOLVED_URL, webView.url ?: lastSeenUrl)
                capturedMediaUrl?.let { putExtra(EXTRA_EXTRACTED_MEDIA_URL, it) }
                capturedAudioUrl?.let { putExtra(EXTRA_EXTRACTED_AUDIO_URL, it) }
            },
        )
        finish()
    }

    private fun finishWithSession() {
        val cookieManager = CookieManager.getInstance()
        cookieManager.flush()

        val combined = LinkedHashMap<String, String>()
        for (url in cookieUrls) {
            val raw = cookieManager.getCookie(url) ?: continue
            for (pair in raw.split(';')) {
                val trimmed = pair.trim()
                val separator = trimmed.indexOf('=')
                if (separator <= 0) continue
                val name = trimmed.substring(0, separator)
                val value = trimmed.substring(separator + 1)
                if (name.isNotBlank()) combined[name] = value
            }
        }
        if (combined.isEmpty()) {
            // Nothing to save (the user closed the page without logging in) —
            // treat like a cancel rather than writing an empty, useless file.
            finishCancelled()
            return
        }

        val domain = cookieUrls.first()
            .removePrefix("https://")
            .removePrefix("http://")
            .let { host -> "." + host.removePrefix("www.") }
        val file = File(filesDir, "cookies/$providerId.txt")
        file.parentFile?.mkdirs()
        file.bufferedWriter().use { writer ->
            writer.appendLine("# Netscape HTTP Cookie File")
            for ((name, value) in combined) {
                writer.appendLine(
                    listOf(domain, "TRUE", "/", "TRUE", "2147483647", name, value)
                        .joinToString("\t"),
                )
            }
        }

        finished = true
        setResult(RESULT_OK)
        finish()
    }

    private fun finishCancelled() {
        finished = true
        setResult(RESULT_CANCELED)
        finish()
    }

    companion object {
        const val EXTRA_PROVIDER_ID = "providerId"
        const val EXTRA_LOGIN_URL = "loginUrl"
        const val EXTRA_COOKIE_URLS = "cookieUrls"
        const val EXTRA_RESOLVE_URL = "resolveUrl"
        const val EXTRA_RESOLVED_URL = "resolvedUrl"
        const val EXTRA_EXTRACTED_MEDIA_URL = "extractedMediaUrl"
        const val EXTRA_EXTRACTED_AUDIO_URL = "extractedAudioUrl"
        private const val STABILITY_POLL_MS = 500L
        // 2 ticks to settle the SPA route + up to 10 more (~5s) giving a
        // Story page's video player time to actually issue its fbcdn.net
        // request before giving up on finding one.
        private const val STORY_EXTRA_TICKS = 12
        private const val RESOLVE_TIMEOUT_MS = 16_000L
        private const val DESKTOP_USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    }
}
