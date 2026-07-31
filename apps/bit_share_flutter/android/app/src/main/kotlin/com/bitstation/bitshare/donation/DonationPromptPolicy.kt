package com.bitstation.bitshare.donation

internal object DonationPromptPolicy {
    const val interval = 5

    fun nextCount(previousCount: Int): Int {
        return if (previousCount < 0 || previousCount == Int.MAX_VALUE) {
            1
        } else {
            previousCount + 1
        }
    }

    fun shouldPrompt(completedDownloadCount: Int): Boolean {
        return completedDownloadCount > 0 &&
            completedDownloadCount % interval == 0
    }
}
