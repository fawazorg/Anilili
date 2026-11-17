package com.anilili.history

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class WatchProgressPolicyTest {
    @Test fun androidCompletionKeepsTheExistingWholeEpisodeAndMinuteRules() {
        assertFalse(WatchProgressPolicy.androidCompleted(1.5, 90_000, 100_000, 80))
        assertFalse(WatchProgressPolicy.androidCompleted(0.0, 90_000, 100_000, 80))
        assertFalse(WatchProgressPolicy.androidCompleted(Double.NaN, 90_000, 100_000, 80))
        assertFalse(WatchProgressPolicy.androidCompleted(1.0, 59_000, 59_999, 80))
        assertFalse(WatchProgressPolicy.androidCompleted(1.0, 79_999, 100_000, 80))
        assertTrue(WatchProgressPolicy.androidCompleted(1.0, 80_000, 100_000, 80))
        assertFalse(WatchProgressPolicy.androidCompleted(1.0, 49_999, 100_000, 1))
        assertTrue(WatchProgressPolicy.androidCompleted(1.0, 95_000, 100_000, 100))
    }

    @Test fun androidResumeKeepsExactPositionWithoutClampingOrPreroll() {
        assertEquals(150_000L, WatchProgressPolicy.resumePositionMs(150_000, 100_000, false))
        assertEquals(0L, WatchProgressPolicy.resumePositionMs(15_000, 100_000, true))
        assertEquals(0L, WatchProgressPolicy.resumePositionMs(-1, 100_000, false))
        assertEquals(97_000L, WatchProgressPolicy.resumePositionMs(150_000, 100_000, false, 3_000, true))
        assertFalse(WatchProgressPolicy.validPositionMs(-1))
        assertTrue(WatchProgressPolicy.validPositionMs(0))
    }

    @Test fun historyOrderingIsStableForEqualTimestamps() {
        val rows = listOf("a" to 2L, "b" to 1L, "c" to 2L)
        assertEquals(listOf("a", "c", "b"), WatchProgressPolicy.latestFirst(rows) { it.second }.map { it.first })
    }
}
