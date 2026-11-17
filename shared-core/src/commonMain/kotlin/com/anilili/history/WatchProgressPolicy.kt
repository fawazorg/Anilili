package com.anilili.history

/** Shared rules with an explicit Android compatibility path: no storage or clock dependency. */
object WatchProgressPolicy {
    fun validPositionMs(positionMs: Long): Boolean = positionMs >= 0

    fun androidCompleted(episodeNumber: Double, positionMs: Long, durationMs: Long, thresholdPercent: Int): Boolean {
        if (episodeNumber < 1 || episodeNumber % 1.0 != 0.0) return false
        if (durationMs < 60_000 || positionMs <= 0) return false
        return positionMs.toDouble() / durationMs >= thresholdPercent.coerceIn(50, 95) / 100.0
    }

    fun resumePositionMs(positionMs: Long, durationMs: Long, completed: Boolean, rewindMs: Long = 0, clampToDuration: Boolean = false): Long {
        if (completed || positionMs <= 0) return 0
        val position = if (clampToDuration && durationMs > 0) positionMs.coerceAtMost(durationMs) else positionMs
        return (position - rewindMs.coerceAtLeast(0)).coerceAtLeast(0)
    }

    fun <T> latestFirst(entries: List<T>, updatedAt: (T) -> Long): List<T> = entries.sortedByDescending(updatedAt)
}
