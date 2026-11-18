package com.anilili.downloads

import com.anilili.episodes.PlaybackFormat
import kotlinx.serialization.json.*
import kotlin.test.*

class DownloadRepositoryTest {
    private val id = DownloadIdentity("anipm", "101", "anipm:sub:1")
    private fun repo(storage: Store = Store()) = DownloadRepository(storage)
    private fun queued(repository: DownloadRepository, identity: DownloadIdentity = id, format: PlaybackFormat = PlaybackFormat.MP4) =
        repository.enqueue(identity, "Original anime", "Episode 1", format, 10, 1)
    private fun started(repository: DownloadRepository, identity: DownloadIdentity = id): DownloadSession {
        queued(repository, identity)
        return requireNotNull(repository.begin(identity, 20).session)
    }
    private fun row(repository: DownloadRepository, identity: DownloadIdentity = id) = repository.snapshot().records.single { it.identity == identity }
    private fun complete(repository: DownloadRepository, session: DownloadSession, key: String = "original.mp4") =
        repository.complete(session, key, 100, 40)

    @Test fun queuedMetadataOrderAndEpisodeNumberPersistAcrossRecreation() {
        val store = Store(); val repository = repo(store)
        val second = id.copy(episodeId = "anipm:sub:2")
        assertTrue(repository.enqueue(second, "Title", "Episode 2", PlaybackFormat.HLS, 10, 2).accepted)
        assertTrue(queued(repository).accepted)
        val rows = repo(store).snapshot().records
        assertEquals(listOf(second, id), rows.map { it.identity })
        assertEquals(listOf(2, 1), rows.map { it.episodeNumber })
        assertTrue(rows.all { it.state == DownloadState.QUEUED && !it.locallyAvailable })
    }

    @Test fun duplicateRequestsDoNotConsumeQueueOrReplaceTitles() {
        val store = Store(); val repository = repo(store)
        queued(repository); val before = store.content
        assertFalse(repository.enqueue(id, "Changed", "Changed", PlaybackFormat.HLS, 99).accepted)
        assertEquals(before, store.content)
        assertEquals("Original anime", row(repository).title)
    }

    @Test fun providerAnimeAndAudioQualifiedIdentitiesDoNotCollide() {
        val repository = repo()
        for (identity in listOf(id, id.copy(providerId = "anichan"), id.copy(animeId = "102"), id.copy(episodeId = "anipm:dub:1"))) queued(repository, identity)
        assertEquals(4, repository.snapshot().records.size)
    }

    @Test fun onlyQueuedRecordCanBeginAndOnlyOneSessionOwnsTransfer() {
        val repository = repo()
        queued(repository)
        val session = assertNotNull(repository.begin(id, 20).session)
        assertEquals(DownloadState.DOWNLOADING, row(repository).state)
        assertEquals(session.generation, row(repository).generation)
        assertFalse(repository.begin(id, 21).accepted)
        assertNull(repository.begin(id, 22).session)
    }

    @Test fun progressHandlesKnownAndUnknownLengthsWithoutPrematureCompletion() {
        val repository = repo(); val session = started(repository)
        assertTrue(repository.progress(session, 10, 0, 1, 21).accepted)
        assertEquals(0, row(repository).totalBytes)
        assertTrue(repository.progress(session, 100, 100, 2, 22).accepted)
        assertEquals(DownloadState.DOWNLOADING, row(repository).state)
        assertFalse(row(repository).locallyAvailable)
    }

    @Test fun negativeInconsistentAndInvalidProgressCannotModifyStorage() {
        val store = Store(); val repository = repo(store); val session = started(repository)
        val original = store.content
        for ((bytes, total, sequence, now) in listOf(
            listOf(-1L, 100, 1, 30), listOf(10L, -1, 1, 30), listOf(101L, 100, 1, 30),
            listOf(10L, 100, 0, 30), listOf(10L, 100, 1, -1),
        )) assertNotNull(repository.progress(session, bytes, total, sequence, now).error)
        assertEquals(original, store.content)
    }

    @Test fun olderProgressSequenceAndByteRegressionAreIgnored() {
        val store = Store(); val repository = repo(store); val session = started(repository)
        repository.progress(session, 50, 100, 2, 30); val before = store.content
        assertFalse(repository.progress(session, 80, 100, 1, 31).accepted)
        assertFalse(repository.progress(session, 40, 100, 3, 31).accepted)
        assertEquals(before, store.content)
    }

    @Test fun pauseAndResumeInvalidateOldCallbacksAndPermitServerRestartFromZero() {
        val repository = repo(); val old = started(repository)
        repository.progress(old, 50, 100, 1, 30)
        assertTrue(repository.pause(id, 31).accepted)
        assertEquals(50, row(repository).bytesDownloaded)
        assertFalse(repository.complete(old, "stale.mp4", 100, 32).accepted)
        assertTrue(repository.retry(id, 33).accepted)
        val resumed = assertNotNull(repository.begin(id, 34).session)
        assertTrue(resumed.generation > old.generation)
        assertEquals(0, row(repository).bytesDownloaded)
        assertTrue(repository.progress(resumed, 10, 100, 1, 35).accepted)
        assertFalse(repository.progress(old, 100, 100, 2, 36).accepted)
    }

    @Test fun cancellationClearsProgressAndCannotBeOverwrittenByLateCompletion() {
        val repository = repo(); val session = started(repository)
        repository.progress(session, 20, 100, 1, 30)
        assertTrue(repository.cancel(id, 31).accepted)
        assertEquals(DownloadState.CANCELLED, row(repository).state)
        assertEquals(0, row(repository).bytesDownloaded)
        assertFalse(complete(repository, session).accepted)
        assertFalse(repository.pause(id, 50).accepted)
        assertTrue(repository.retry(id, 51).accepted)
    }

    @Test fun failureAndRetryAreExplicitAndOldFailureCannotAffectNewAttempt() {
        val repository = repo(); val old = started(repository)
        assertTrue(repository.fail(old, DownloadErrorKind.NETWORK, 30).accepted)
        assertEquals(DownloadErrorKind.NETWORK, row(repository).failure)
        assertTrue(repository.retry(id, 31).accepted)
        val next = assertNotNull(repository.begin(id, 32).session)
        assertFalse(repository.fail(old, DownloadErrorKind.EXPIRED, 33).accepted)
        assertTrue(repository.progress(next, 20, 100, 1, 34).accepted)
        assertNull(row(repository).failure)
    }

    @Test fun mp4AndHlsCompletionRequireExplicitValidatedLocalHandle() {
        for ((format, key) in listOf(PlaybackFormat.MP4 to "original.mp4", PlaybackFormat.HLS to "original.movpkg")) {
            val repository = repo(); queued(repository, format = format)
            val session = assertNotNull(repository.begin(id, 20).session)
            assertTrue(complete(repository, session, key).accepted)
            assertEquals(format, row(repository).format)
            assertEquals(key, row(repository).localMediaKey)
            assertTrue(row(repository).locallyAvailable)
            assertFalse(complete(repository, session, key).accepted)
        }
    }

    @Test fun unsafeLocalPathsEmptyMediaAndTruncatedTransfersAreRejected() {
        val repository = repo(); val session = started(repository)
        for (key in listOf("", "/outside.mp4", "../escape.mp4", "a/other.mp4", "file://private.mp4", "a%2fb.mp4", "..", ".hidden")) {
            assertNotNull(repository.complete(session, key, 100, 30).error)
        }
        assertNotNull(repository.complete(session, "valid.mp4", 0, 30).error)
        repository.progress(session, 20, 100, 1, 31)
        assertNotNull(repository.complete(session, "valid.mp4", 90, 32).error)
        assertEquals(DownloadState.DOWNLOADING, row(repository).state)
    }

    @Test fun completedRecordsDoNotTransitionBackToActiveByIntent() {
        val repository = repo(); complete(repository, started(repository))
        assertFalse(repository.pause(id, 50).accepted)
        assertFalse(repository.cancel(id, 50).accepted)
        assertFalse(repository.retry(id, 50).accepted)
        assertFalse(repository.begin(id, 50).accepted)
        assertTrue(row(repository).locallyAvailable)
    }

    @Test fun missingOrCorruptLocalMediaBecomesExplicitFailureAndCanRetry() {
        for (kind in listOf(DownloadErrorKind.MISSING, DownloadErrorKind.CORRUPT)) {
            val repository = repo(); complete(repository, started(repository))
            assertTrue(repository.markUnavailable(id, kind, 50).accepted)
            assertEquals(DownloadState.FAILED, row(repository).state)
            assertEquals(kind, row(repository).failure)
            assertNull(row(repository).localMediaKey)
            assertTrue(repository.retry(id, 51).accepted)
        }
    }

    @Test fun recreationRecoveryPausesQueuedAndActiveRowsButKeepsCompleted() {
        val store = Store(); val repository = repo(store)
        val first = started(repository)
        val queuedId = id.copy(episodeId = "anipm:sub:2"); queued(repository, queuedId)
        val completedId = id.copy(episodeId = "anipm:sub:3")
        val completed = started(repository, completedId); complete(repository, completed, "third.mp4")
        val recreated = repo(store)
        assertTrue(recreated.recoverInterrupted(100).accepted)
        assertEquals(listOf(DownloadState.PAUSED, DownloadState.PAUSED, DownloadState.COMPLETED), recreated.snapshot().records.map { it.state })
        assertFalse(recreated.progress(first, 100, 100, 1, 101).accepted)
        assertFalse(recreated.recoverInterrupted(102).accepted)
    }

    @Test fun corruptAndUnsupportedMetadataIsPreservedWithoutSilentReset() {
        for (content in listOf("broken", "[]", "{}", """{"version":2,"records":[]}""", """{"version":1,"nextGeneration":0}""")) {
            val store = Store(content); val repository = repo(store)
            assertNotNull(repository.snapshot().error)
            assertNotNull(queued(repository).error)
            assertEquals(content, store.content)
            assertEquals(0, store.writes)
        }
    }

    @Test fun malformedDuplicateAndUnsafeStoredRowsCannotTriggerDeletionOrNewWrites() {
        val source = Store(); val repository = repo(source); complete(repository, started(repository))
        val root = Json.parseToJsonElement(assertNotNull(source.content)).jsonObject
        val record = root["records"]!!.jsonArray.single().jsonObject
        val badRecords = listOf(
            JsonArray(listOf(record, record)),
            JsonArray(listOf(JsonObject(record + ("localMediaKey" to JsonPrimitive("../other.mp4"))))),
            JsonArray(listOf(JsonObject(record + ("bytesDownloaded" to JsonPrimitive(-1))))),
            JsonArray(listOf(JsonObject(record + ("episodeNumber" to JsonPrimitive(0))))),
        )
        for (rows in badRecords) {
            val content = JsonObject(root + ("records" to rows)).toString()
            val store = Store(content); val bad = repo(store)
            assertNotNull(bad.snapshot().error)
            assertNotNull(bad.remove(id).error)
            assertEquals(content, store.content)
        }
    }

    @Test fun storageErrorsNeverReportUnpersistedSuccess() {
        val store = Store(); val repository = repo(store)
        store.readError = "Storage read failed"
        assertEquals("Storage read failed", queued(repository).error)
        assertNull(store.content)
        store.readError = null; store.writeError = "Disk full"
        val result = queued(repository)
        assertFalse(result.accepted); assertEquals("Disk full", result.error)
        assertTrue(result.records.isEmpty()); assertNull(store.content)
    }

    @Test fun compareAndSetConflictRetriesAgainstFreshStateWithoutLosingOtherQueueRow() {
        val store = Store(); val first = repo(store); val second = repo(store)
        val other = id.copy(providerId = "anichan")
        store.beforeWrite = { queued(second, other) }
        assertTrue(queued(first).accepted)
        assertEquals(setOf(id, other), first.snapshot().records.map { it.identity }.toSet())
        assertEquals(3, store.writes)
    }

    @Test fun contendedStorageStopsAfterBoundedAttempts() {
        val store = Store(); store.alwaysConflict = true
        val result = queued(repo(store))
        assertFalse(result.accepted); assertNotNull(result.error)
        assertEquals(32, store.writes); assertNull(store.content)
    }

    @Test fun removalThenReenqueueNeverReusesOldTransferGeneration() {
        val store = Store(); val repository = repo(store); val old = started(repository)
        assertNotNull(repository.remove(id).error)
        assertTrue(repository.cancel(id, 30).accepted)
        assertTrue(repository.remove(id).accepted)
        assertTrue(queued(repo(store)).accepted)
        val fresh = assertNotNull(repo(store).begin(id, 40).session)
        assertTrue(fresh.generation > old.generation)
        assertFalse(repository.complete(old, "old.mp4", 100, 41).accepted)
        assertTrue(repository.complete(fresh, "new.mp4", 100, 42).accepted)
    }

    @Test fun twoRecordsCannotClaimOneNativeFile() {
        val repository = repo(); complete(repository, started(repository), "shared.mp4")
        val other = id.copy(episodeId = "anipm:sub:2"); val session = started(repository, other)
        assertNotNull(repository.complete(session, "shared.mp4", 100, 50).error)
        assertEquals(DownloadState.DOWNLOADING, row(repository, other).state)
    }

    @Test fun exhaustedGenerationAndQueueCountersFailWithoutOverflow() {
        for (field in listOf("nextGeneration", "nextQueueOrder")) {
            val content = """{"version":1,"$field":${Long.MAX_VALUE},"records":[]}"""
            val store = Store(content)
            assertNotNull(queued(repo(store)).error)
            assertEquals(content, store.content)
        }
    }

    @Test fun clockCorrectionDoesNotBlockPauseOrCorruptOrdering() {
        val repository = repo(); val session = started(repository)
        assertTrue(repository.progress(session, 10, 100, 1, 15).accepted)
        assertEquals(20, row(repository).updatedAtMs)
        assertTrue(repository.pause(id, 5).accepted)
        assertEquals(20, row(repository).updatedAtMs)
    }

    @Test fun invalidMetadataAndTimestampsFailWithoutQueueChanges() {
        val repository = repo()
        assertNotNull(repository.enqueue(id.copy(providerId = ""), "Title", "Ep", PlaybackFormat.MP4, 1).error)
        assertNotNull(repository.enqueue(id, "", "Ep", PlaybackFormat.MP4, 1).error)
        assertNotNull(repository.enqueue(id, "Title", "Ep", PlaybackFormat.MP4, -1).error)
        assertNotNull(repository.enqueue(id, "Title", "Ep", PlaybackFormat.MP4, 1, 0).error)
        assertTrue(repository.snapshot().records.isEmpty())
    }

    @Test fun durableMetadataContainsNoSourceRequestOrResumeBlobFields() {
        val store = Store(); queued(repo(store))
        val document = assertNotNull(store.content)
        for (privateField in listOf("https://", "http://", "Cookie", "Authorization", "headers", "resumeData", "sourceUrl")) assertFalse(document.contains(privateField))
    }

    private class Store(var content: String? = null) : DownloadStorage {
        var readError: String? = null
        var writeError: String? = null
        var writes = 0
        var alwaysConflict = false
        var beforeWrite: (() -> Unit)? = null
        override fun read() = DownloadStorageRead(content, readError)
        override fun compareAndSet(expected: String?, updated: String): DownloadStorageWrite {
            writes++
            beforeWrite?.let { beforeWrite = null; it() }
            if (writeError != null) return DownloadStorageWrite(false, writeError)
            if (alwaysConflict || content != expected) return DownloadStorageWrite(false)
            content = updated
            return DownloadStorageWrite(true)
        }
    }
}
