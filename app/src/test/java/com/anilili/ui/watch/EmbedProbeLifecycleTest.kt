package com.anilili.ui.watch

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EmbedProbeLifecycleTest {
    private val episode = "https://example.invalid/episode-1"

    @Test
    fun lateRendererResultCannotUpdateAfterPageChangeOrEffectCancellation() {
        assertFalse(shouldApplyEmbedProbe(true, true, episode, "https://example.invalid/episode-2", 0, 3_000))
        assertFalse(shouldApplyEmbedProbe(false, true, episode, episode, 0, 3_000))
        assertFalse(shouldApplyEmbedProbe(true, false, episode, episode, 0, 3_000))
    }

    @Test
    fun bridgeTickThatArrivesWhileProbeIsInFlightSupersedesItsResult() {
        assertTrue(shouldApplyEmbedProbe(true, true, episode, episode, 100, 3_000))
        assertFalse(shouldApplyEmbedProbe(true, true, episode, episode, 3_010, 3_020))
    }

    @Test
    fun anActivePageWithoutBridgeDataCanUseTheFallbackImmediately() {
        assertTrue(shouldApplyEmbedProbe(true, true, episode, episode, 0, 1_000))
    }
}
