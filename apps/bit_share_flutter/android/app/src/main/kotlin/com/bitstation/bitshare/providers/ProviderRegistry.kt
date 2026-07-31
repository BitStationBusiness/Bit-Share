package com.bitstation.bitshare.providers

import java.net.URI
import java.net.InetAddress

internal data class ProviderMatch(
    val id: String,
    val displayName: String,
)

internal object ProviderRegistry {
    private val knownProviders = listOf(
        ProviderDefinition("facebook", "Facebook", setOf("facebook.com", "fb.watch")),
        ProviderDefinition("x", "X", setOf("x.com", "twitter.com")),
        ProviderDefinition("youtube", "YouTube", setOf("youtube.com", "youtu.be")),
        ProviderDefinition("instagram", "Instagram", setOf("instagram.com")),
        ProviderDefinition("threads", "Threads", setOf("threads.com")),
        ProviderDefinition("tiktok", "TikTok", setOf("tiktok.com")),
        ProviderDefinition("vimeo", "Vimeo", setOf("vimeo.com")),
        ProviderDefinition("reddit", "Reddit", setOf("reddit.com", "redd.it")),
    )

    fun resolve(rawUrl: String): ProviderMatch? {
        val uri = runCatching { URI(rawUrl.trim()) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase()
        if (scheme != "https" && scheme != "http") return null
        if (uri.rawUserInfo != null) return null
        val host = uri.host?.lowercase()?.trimEnd('.') ?: return null
        if (host.isBlank() || isLocalOrPrivateHost(host)) return null

        return knownProviders.firstNotNullOfOrNull { provider ->
            if (provider.hosts.any { host == it || host.endsWith(".$it") }) {
                ProviderMatch(provider.id, provider.displayName)
            } else {
                null
            }
        } ?: ProviderMatch("web", displayNameFor(host))
    }

    private fun displayNameFor(host: String): String {
        return host.removePrefix("www.").ifBlank { "Sitio web" }
    }

    private fun isLocalOrPrivateHost(host: String): Boolean {
        if (
            host == "localhost" ||
            host.endsWith(".localhost") ||
            host.endsWith(".local") ||
            host.endsWith(".internal")
        ) {
            return true
        }

        val ipv4 = host.split('.').map { it.toIntOrNull() }
        if (ipv4.size == 4 && ipv4.all { it != null && it in 0..255 }) {
            val first = ipv4[0]!!
            val second = ipv4[1]!!
            return first == 0 ||
                first == 10 ||
                first == 127 ||
                (first == 100 && second in 64..127) ||
                (first == 169 && second == 254) ||
                (first == 172 && second in 16..31) ||
                (first == 192 && second == 168) ||
                (first == 198 && second in 18..19) ||
                first >= 224
        }

        if (!host.contains(':')) return false
        val address = runCatching { InetAddress.getByName(host) }.getOrNull() ?: return true
        val bytes = address.address
        val isUniqueLocalIpv6 =
            bytes.size == 16 && (bytes[0].toInt() and 0xfe) == 0xfc
        return address.isAnyLocalAddress ||
            address.isLoopbackAddress ||
            address.isLinkLocalAddress ||
            address.isSiteLocalAddress ||
            address.isMulticastAddress ||
            isUniqueLocalIpv6
    }

    private data class ProviderDefinition(
        val id: String,
        val displayName: String,
        val hosts: Set<String>,
    )
}
