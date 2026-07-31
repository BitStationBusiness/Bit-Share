package com.bitstation.bitshare.auth

/**
 * Providers whose content sometimes sits behind a login wall (a private
 * post, a share link Facebook only resolves for a signed-in viewer, an
 * age-gated video, ...). Each entry names the page LoginSessionActivity
 * opens and which cookie domains are worth exporting afterwards — sites
 * commonly split their session cookies across a bare domain, `www.` and a
 * mobile subdomain, so all are captured.
 */
internal object ProviderLogin {
    private val targets = mapOf(
        "facebook" to LoginTarget(
            loginUrl = "https://www.facebook.com/login/",
            cookieUrls = listOf(
                "https://www.facebook.com",
                "https://facebook.com",
                "https://m.facebook.com",
            ),
        ),
        "instagram" to LoginTarget(
            loginUrl = "https://www.instagram.com/accounts/login/",
            cookieUrls = listOf(
                "https://www.instagram.com",
                "https://instagram.com",
            ),
        ),
        "tiktok" to LoginTarget(
            loginUrl = "https://www.tiktok.com/login",
            cookieUrls = listOf(
                "https://www.tiktok.com",
                "https://tiktok.com",
            ),
        ),
        "x" to LoginTarget(
            loginUrl = "https://x.com/login",
            cookieUrls = listOf(
                "https://x.com",
                "https://twitter.com",
            ),
        ),
        "threads" to LoginTarget(
            loginUrl = "https://www.threads.com/login/",
            cookieUrls = listOf(
                "https://www.threads.com",
                "https://threads.com",
            ),
        ),
    )

    fun forProvider(providerId: String): LoginTarget? = targets[providerId]

    /** [providerId] is also the file name under filesDir/cookies/, so it must
     * be one of our own known ids — never attacker- or site-controlled. */
    internal data class LoginTarget(
        val loginUrl: String,
        val cookieUrls: List<String>,
    )
}
