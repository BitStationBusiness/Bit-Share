package com.bitstation.bitshare.donation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DonationPromptPolicyTest {
    @Test
    fun `prompts every five completed downloads`() {
        assertFalse(DonationPromptPolicy.shouldPrompt(1))
        assertFalse(DonationPromptPolicy.shouldPrompt(4))
        assertTrue(DonationPromptPolicy.shouldPrompt(5))
        assertFalse(DonationPromptPolicy.shouldPrompt(6))
        assertTrue(DonationPromptPolicy.shouldPrompt(10))
    }

    @Test
    fun `counter wraps safely`() {
        assertEquals(1, DonationPromptPolicy.nextCount(Int.MAX_VALUE))
        assertEquals(5, DonationPromptPolicy.nextCount(4))
    }
}
