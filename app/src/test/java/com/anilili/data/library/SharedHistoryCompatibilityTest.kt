package com.anilili.data.library

import com.anilili.ui.watch.shouldSyncAniListProgress
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.*
import org.junit.Test

/** Legacy Android storage and policies remain compatible while their decisions are shared. */
class SharedHistoryCompatibilityTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private fun row(id: Int = 1, updatedAt: Long = 0) = HistoryEntry(
        anilistId = id, title = "Fixture", cover = null, episodeNumber = 1.0,
        provider = "fixture-provider", category = "sub", positionMs = 1_200, durationMs = 5_000,
        updatedAt = updatedAt,
    )

    @Test fun sharedCompletionMatchesEstablishedAndroidPolicy() {
        for (episode in listOf(0.0, 1.0, 1.5, Double.NaN, Double.POSITIVE_INFINITY)) {
            for (duration in listOf(0L, 59_999L, 60_000L, 1_440_000L)) {
                for (position in listOf(-1L, 0L, 30_000L, 48_000L, 1_200_000L)) {
                    for (threshold in listOf(0, 50, 80, 90, 95, 100)) {
                        val expected = !(episode < 1 || episode % 1.0 != 0.0 || duration < 60_000 || position <= 0) &&
                            position.toDouble() / duration >= threshold.coerceIn(50, 95) / 100.0
                        assertEquals(expected, shouldSyncAniListProgress(episode, position, duration, threshold))
                    }
                }
            }
        }
    }

    @Test fun oldPersistedRowsKeepFieldsAndResumeAfterRepositoryRecreation() {
        val legacy = """{"anilistId":12,"title":"Legacy","cover":null,"episodeNumber":2.5,"provider":"old-provider","category":"dub","positionMs":720000,"durationMs":1440000,"updatedAt":123,"watchedEpisodes":[1.0],"resumePoints":{"2.5":{"positionMs":720000,"durationMs":1440000}}}"""
        val first = json.decodeFromString(HistoryEntry.serializer(), legacy)
        val encoded = json.encodeToString(HistoryEntry.serializer(), first)
        val recreated = json.decodeFromString(HistoryEntry.serializer(), encoded)
        assertEquals(first, recreated)
        assertEquals(720_000L, recreated.resumeFor(2.5)!!.positionMs)
        assertEquals("old-provider", recreated.provider)
        assertNull(recreated.resumeFor(1.0))
        assertEquals(setOf("anilistId", "title", "cover", "episodeNumber", "episodeTitle", "provider", "category", "positionMs", "durationMs", "updatedAt", "watchedEpisodes", "fromRemote", "resumePoints"),
            json.parseToJsonElement(encoded).jsonObject.keys)
    }

    @Test fun androidResumeHasNoPrerollOrNewDurationClampAndAllowsBackwardSeeking() {
        val unknown = row().copy(positionMs = 3_000, durationMs = 0)
        assertEquals(3_000L, unknown.resumeFor(1.0)!!.positionMs)
        val overDuration = row().copy(positionMs = 6_000, durationMs = 5_000)
        assertEquals(6_000L, overDuration.resumeFor(1.0)!!.positionMs)
        val original = row()
        assertSame(original, original.withEpisodeProgress(1.0, -1, 5_000))
        val rewound = row().withEpisodeProgress(1.0, 500, 5_000)
        assertEquals(500L, rewound.resumeFor(1.0)!!.positionMs)
        assertNull(rewound.copy(watchedEpisodes = setOf(1.0)).resumeFor(1.0))
    }

    @Test fun continueWatchingKeepsStableNewestFirstOrderAndCanonicalTitleDeduplication() {
        val a = row(1, 100)
        val b = row(2, 200)
        val c = row(3, 200)
        assertEquals(listOf(2, 3, 1), sortHistoryLatestFirst(listOf(a, b, c)).map { it.anilistId })
        assertEquals(listOf(2, 3, 1), mergedHistory(listOf(a, b, c), listOf(a.copy(provider = "another-provider")), 100).map { it.anilistId })
    }
}
