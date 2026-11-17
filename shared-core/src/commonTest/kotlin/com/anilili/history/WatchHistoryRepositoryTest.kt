package com.anilili.history

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class WatchHistoryRepositoryTest {
    private val identity = WatchIdentity("provider-a", "anime-1", "episode-1")
    private val rules = WatchHistoryRules()
    private fun repository(store: MemoryHistoryStorage) = WatchHistoryRepository(store, rules)
    private fun start(repo: WatchHistoryRepository, id: WatchIdentity = identity, now: Long = 100) =
        requireNotNull(repo.beginSession(id, "Title", "Episode", now).session)

    @Test fun progressPersistsAcrossRepositoryRecreationAndResumesWithPreroll() {
        val store = MemoryHistoryStorage()
        val repo = repository(store)
        val session = start(repo)
        assertTrue(repo.update(session, 25_000.0, 100_000.0, 200, 1).accepted)
        val recreated = repository(store)
        val row = recreated.snapshot().records.single()
        assertEquals(25_000, row.positionMs)
        assertEquals(22_000, recreated.resumePosition(row))
        assertEquals(row, recreated.continueWatching().records.single())
    }

    @Test fun completionThresholdAndShortMediaSafeguardAreConfigurable() {
        val store = MemoryHistoryStorage()
        val repo = repository(store)
        val session = start(repo)
        assertFalse(repo.update(session, 89_999.0, 100_000.0, 200, 1).records.single().completed)
        assertTrue(repo.update(session, 90_000.0, 100_000.0, 201, 2).records.single().completed)
        assertTrue(repo.continueWatching().records.isEmpty())
        assertEquals(0, repo.resumePosition(repo.snapshot().records.single()))
        val short = start(repo, WatchIdentity("p", "short", "1"))
        assertFalse(repo.update(short, 11_000.0, 12_000.0, 300, 1).records.first().completed)
        val custom = WatchHistoryRepository(MemoryHistoryStorage(), WatchHistoryRules(80, 10_000, 1_000, 8_000))
        val customSession = start(custom)
        assertTrue(custom.update(customSession, 8_000.0, 10_000.0, 200, 1).records.single().completed)
    }

    @Test fun unknownDurationAndBackwardSeekingRemainValid() {
        val repo = repository(MemoryHistoryStorage())
        val session = start(repo)
        assertTrue(repo.update(session, 50_000.0, 0.0, 200, 1).accepted)
        assertFalse(repo.snapshot().records.single().completed)
        assertTrue(repo.update(session, 10_000.0, 100_000.0, 201, 2).accepted)
        assertEquals(10_000, repo.snapshot().records.single().positionMs)
    }

    @Test fun rejectsInvalidPositionsDurationsAndTimestampsWithoutWriting() {
        val store = MemoryHistoryStorage()
        val repo = repository(store)
        val session = start(repo)
        val original = store.content
        for (position in listOf(-1.0, Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, Long.MAX_VALUE.toDouble())) {
            assertNotNull(repo.update(session, position, 100_000.0, 200, 1).error)
        }
        for (duration in listOf(-1.0, Double.NaN, Double.POSITIVE_INFINITY)) {
            assertNotNull(repo.update(session, 1_000.0, duration, 200, 1).error)
        }
        assertNotNull(repo.update(session, 1_000.0, 100_000.0, -1, 1).error)
        assertNotNull(repo.update(session, 1_000.0, 100_000.0, 200, 0).error)
        assertEquals(original, store.content)
        assertNotNull(repo.beginSession(WatchIdentity("", "a", "b"), "T", "E", 0).error)
    }

    @Test fun identitiesDoNotCollideAndContinueWatchingIsSorted() {
        val repo = repository(MemoryHistoryStorage())
        val ids = listOf(identity, identity.copy(providerId = "provider-b"), identity.copy(animeId = "anime-2"), identity.copy(episodeId = "episode-2"))
        for ((index, id) in ids.withIndex()) {
            val session = start(repo, id)
            repo.update(session, 10_000.0, 100_000.0, 200L + index, 1)
        }
        assertEquals(ids.reversed(), repo.continueWatching().records.map { it.identity })
        assertEquals(4, repo.snapshot().records.size)
    }

    @Test fun olderSessionsAndOutOfOrderUpdatesCannotOverwriteNewerProgress() {
        val store = MemoryHistoryStorage()
        val repo = repository(store)
        val old = start(repo)
        val newer = start(repository(store), now = 200)
        assertTrue(repo.update(newer, 30_000.0, 100_000.0, 300, 2).accepted)
        assertFalse(repo.update(old, 50_000.0, 100_000.0, 400, 9).accepted)
        assertFalse(repo.update(newer, 40_000.0, 100_000.0, 301, 1).accepted)
        assertFalse(repo.update(newer, 40_000.0, 100_000.0, 299, 3).accepted)
        assertEquals(30_000, repo.snapshot().records.single().positionMs)
        assertTrue(repo.update(newer, 15_000.0, 100_000.0, 300, 3).accepted)
        assertEquals(15_000, repo.snapshot().records.single().positionMs)
    }

    @Test fun markingWatchedOrUnwatchedInvalidatesTheOldPlaybackSession() {
        val repo = repository(MemoryHistoryStorage())
        val session = start(repo)
        repo.update(session, 25_000.0, 100_000.0, 200, 1)
        assertTrue(repo.mark(identity, "Title", "Episode", true, 300).records.single().completed)
        assertFalse(repo.update(session, 30_000.0, 100_000.0, 400, 2).accepted)
        val unmarked = repo.mark(identity, "Title", "Episode", false, 400).records.single()
        assertFalse(unmarked.completed)
        assertEquals(0, unmarked.positionMs)
        assertTrue(repo.continueWatching().records.isEmpty())
    }

    @Test fun completedEpisodeReplayStartsAtZeroWithANewSession() {
        val repo = repository(MemoryHistoryStorage())
        repo.mark(identity, "Title", "Episode", true, 100)
        val result = repo.beginSession(identity, "Title", "Episode", 200)
        assertEquals(0, result.records.single().positionMs)
        assertTrue(result.records.single().completed)
        assertEquals(0, repo.resumePosition(result.records.single()))
        assertNotNull(result.session)
    }

    @Test fun openingAnEpisodeDoesNotCreateFalseContinueWatchingProgressOrReorderHistory() {
        val repo = repository(MemoryHistoryStorage())
        val session = start(repo)
        repo.update(session, 10_000.0, 100_000.0, 200, 1)
        start(repo, now = 999)
        assertEquals(200, repo.continueWatching().records.single().updatedAtMs)
        start(repo, identity.copy(episodeId = "new"), 1_000)
        assertEquals(1, repo.continueWatching().records.size)
    }

    @Test fun malformedAndFutureDataIsPreservedAndErrorsAreExplicit() {
        for (data in listOf("bad json", "{}", "[]", """{"version":2,"records":[]}""", """{"version":1,"records":[{}]}""")) {
            val store = MemoryHistoryStorage(data)
            val repo = repository(store)
            assertNotNull(repo.snapshot().error)
            assertNotNull(repo.beginSession(identity, "Title", "Episode", 100).error)
            assertEquals(data, store.content)
        }
        val missing = repository(MemoryHistoryStorage()).snapshot()
        assertNull(missing.error)
        assertTrue(missing.records.isEmpty())
    }

    @Test fun conflictingConcurrentWriterIsRetriedWithoutLosingItsRecord() {
        val store = MemoryHistoryStorage()
        val other = identity.copy(episodeId = "other")
        store.beforeNextWrite = { start(repository(store), other) }
        val result = repository(store).beginSession(identity, "Title", "Episode", 100)
        assertTrue(result.accepted)
        assertEquals(setOf(identity, other), result.records.map { it.identity }.toSet())
    }

    @Test fun duplicateStoredRecordsAreCollapsedByStableIdentityAndNewestUpdate() {
        val store = MemoryHistoryStorage()
        val repo = repository(store)
        val session = start(repo)
        repo.update(session, 10_000.0, 100_000.0, 200, 1)
        val body = requireNotNull(store.content)
        val row = body.substringAfter("\"records\":[").substringBeforeLast("]")
        store.content = """{"version":1,"records":[$row,${row.replace("\"positionMs\":10000", "\"positionMs\":20000").replace("\"updatedAtMs\":200", "\"updatedAtMs\":300")}]}"""
        val records = repo.snapshot().records
        assertEquals(1, records.size)
        assertEquals(20_000, records.single().positionMs)
    }

    @Test fun storageFailuresNeverReportAnAcceptedWrite() {
        val store = MemoryHistoryStorage()
        val repo = repository(store)
        store.readError = "Read failed"
        assertEquals("Read failed", repo.snapshot().error)
        store.readError = null
        store.writeError = "Write failed"
        val result = repo.beginSession(identity, "Title", "Episode", 100)
        assertFalse(result.accepted)
        assertEquals("Write failed", result.error)
        assertNull(store.content)
    }
}

private class MemoryHistoryStorage(var content: String? = null) : WatchHistoryStorage {
    var beforeNextWrite: (() -> Unit)? = null
    var readError: String? = null
    var writeError: String? = null
    override fun read() = HistoryStorageRead(content, readError)
    override fun compareAndSet(expected: String?, updated: String): HistoryStorageWrite {
        beforeNextWrite?.let { beforeNextWrite = null; it() }
        if (writeError != null) return HistoryStorageWrite(false, writeError)
        if (content != expected) return HistoryStorageWrite(false)
        content = updated
        return HistoryStorageWrite(true)
    }
}
