package com.bitstation.bitshare.providers

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ProviderRegistryTest {
    @Test
    fun resolvesKnownAndGenericPublicWebHosts() {
        assertEquals(
            "facebook",
            ProviderRegistry.resolve("https://www.facebook.com/share/r/example/")?.id,
        )
        assertEquals(
            "x",
            ProviderRegistry.resolve("https://x.com/i/status/123")?.id,
        )
        assertEquals(
            "youtube",
            ProviderRegistry.resolve("https://www.youtube.com/watch?v=jNQXAC9IVRw")?.id,
        )
        assertEquals(
            "threads",
            ProviderRegistry.resolve("https://www.threads.com/share/example/")?.id,
        )
        assertEquals(
            ProviderMatch("web", "media.example.org"),
            ProviderRegistry.resolve("https://media.example.org/watch/123"),
        )
    }

    @Test
    fun rejectsNonWebCredentialsAndLocalHosts() {
        assertNull(ProviderRegistry.resolve("https://user:secret@example.com/video"))
        assertNull(ProviderRegistry.resolve("http://127.0.0.1/video"))
        assertNull(ProviderRegistry.resolve("http://192.168.1.20/video"))
        assertNull(ProviderRegistry.resolve("http://[::1]/video"))
        assertNull(ProviderRegistry.resolve("https://media.local/video"))
        assertNull(ProviderRegistry.resolve("file:///data/local/tmp/video"))
    }
}
