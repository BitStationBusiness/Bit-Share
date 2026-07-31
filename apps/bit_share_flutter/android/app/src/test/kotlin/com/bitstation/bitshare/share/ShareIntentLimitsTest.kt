package com.bitstation.bitshare.share

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ShareIntentLimitsTest {
    @Test
    fun acceptsSupportedMimeTypes() {
        assertTrue(ShareIntentLimits.acceptsMime("text/plain"))
        assertTrue(ShareIntentLimits.acceptsMime("image/png"))
        assertTrue(ShareIntentLimits.acceptsMime("audio/mpeg"))
        assertTrue(ShareIntentLimits.acceptsMime("video/mp4"))
    }

    @Test
    fun rejectsUnsupportedMimeTypes() {
        assertFalse(ShareIntentLimits.acceptsMime("application/x-executable"))
    }
}
