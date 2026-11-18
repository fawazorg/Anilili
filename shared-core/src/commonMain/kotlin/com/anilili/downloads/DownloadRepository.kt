package com.anilili.downloads

import com.anilili.episodes.PlaybackFormat
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

@Serializable
data class DownloadIdentity(val providerId: String, val animeId: String, val episodeId: String)
@Serializable
enum class DownloadState { QUEUED, DOWNLOADING, PAUSED, COMPLETED, FAILED, CANCELLED }
@Serializable
enum class DownloadErrorKind { NETWORK, HTTP, AUTHENTICATION, EXPIRED, NO_SPACE, CORRUPT, MISSING, UNSUPPORTED, STORAGE, CANCELLED }
@Serializable
data class DownloadRecord(
    val identity: DownloadIdentity,
    val title: String,
    val episodeTitle: String,
    val format: PlaybackFormat,
    val episodeNumber: Int = 1,
    val state: DownloadState = DownloadState.QUEUED,
    val bytesDownloaded: Long = 0,
    /** Zero means unknown; fractional HLS time-range progress stays in the native adapter. */
    val totalBytes: Long = 0,
    val generation: Long = 0,
    val lastSequence: Long = 0,
    val queueOrder: Long = 0,
    val updatedAtMs: Long = 0,
    /** An opaque sandbox filename, never an absolute path, URL, credential or resume blob. */
    val localMediaKey: String? = null,
    val failure: DownloadErrorKind? = null,
) {
    val locallyAvailable: Boolean get() = state == DownloadState.COMPLETED && localMediaKey != null
}
data class DownloadSession(val identity: DownloadIdentity, val generation: Long)
data class DownloadStorageRead(val content: String?, val error: String? = null)
data class DownloadStorageWrite(val written: Boolean, val error: String? = null)
interface DownloadStorage {
    fun read(): DownloadStorageRead
    /** Adapters for the same path must atomically compare and durably replace under one lock. */
    fun compareAndSet(expected: String?, updated: String): DownloadStorageWrite
}
data class DownloadResult(
    val records: List<DownloadRecord> = emptyList(),
    val session: DownloadSession? = null,
    val accepted: Boolean = false,
    val error: String? = null,
)
@Serializable
private data class DownloadDocument(
    val version: Int = 1,
    val nextGeneration: Long = 1,
    val nextQueueOrder: Long = 1,
    val records: List<DownloadRecord> = emptyList(),
)

/** Domain-only state machine. Native engines own transfers, validation, local files and cleanup.
 * A fresh global generation survives deletion/re-enqueue, so old callbacks cannot revive media.
 * No source URL, request headers, cookies, tokens or native resume data enters this document. */
class DownloadRepository(private val storage: DownloadStorage) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun snapshot(): DownloadResult {
        val read = storage.read()
        if (read.error != null) return DownloadResult(error = read.error)
        return try { DownloadResult(records = decode(read.content).records) }
        catch (_: InvalidDocument) { DownloadResult(error = "Invalid download metadata; existing data preserved") }
    }

    fun enqueue(identity: DownloadIdentity, title: String, episodeTitle: String, format: PlaybackFormat, nowMs: Long): DownloadResult =
        enqueue(identity, title, episodeTitle, format, nowMs, 1)

    fun enqueue(identity: DownloadIdentity, title: String, episodeTitle: String, format: PlaybackFormat, nowMs: Long, episodeNumber: Int): DownloadResult {
        if (!validIdentity(identity) || !validTitle(title) || !validTitle(episodeTitle) || nowMs < 0 || episodeNumber <= 0) return invalid()
        return mutate { document ->
            if (document.records.any { it.identity == identity }) return@mutate unchanged(document)
            if (document.nextQueueOrder == Long.MAX_VALUE || document.nextGeneration == Long.MAX_VALUE) return@mutate exhausted(document)
            val row = DownloadRecord(identity, title, episodeTitle, format, episodeNumber = episodeNumber, generation = document.nextGeneration,
                queueOrder = document.nextQueueOrder, updatedAtMs = nowMs)
            changed(document.copy(nextGeneration = document.nextGeneration + 1,
                nextQueueOrder = document.nextQueueOrder + 1, records = document.records + row))
        }
    }

    /** Call retry for paused/failed/cancelled records first. Each native attempt owns this token.
     * Reset counters because a server may discard native resume data and restart from byte zero. */
    fun begin(identity: DownloadIdentity, nowMs: Long): DownloadResult = transition(identity, nowMs, setOf(DownloadState.QUEUED)) { row, generation ->
        row.copy(state = DownloadState.DOWNLOADING, generation = generation, lastSequence = 0,
            bytesDownloaded = 0, totalBytes = 0, failure = null, localMediaKey = null)
    }.let { result ->
        if (!result.accepted) result else result.copy(session = result.records.firstOrNull { it.identity == identity }?.let { DownloadSession(identity, it.generation) })
    }

    fun progress(session: DownloadSession, bytesDownloaded: Long, totalBytes: Long, sequence: Long, nowMs: Long): DownloadResult {
        if (bytesDownloaded < 0 || totalBytes < 0 || totalBytes > 0 && bytesDownloaded > totalBytes || sequence <= 0 || nowMs < 0) return invalid()
        return mutate { document ->
            val old = current(document, session) ?: return@mutate unchanged(document)
            if (sequence <= old.lastSequence || bytesDownloaded < old.bytesDownloaded) return@mutate unchanged(document)
            val row = old.copy(bytesDownloaded = bytesDownloaded, totalBytes = totalBytes,
                lastSequence = sequence, updatedAtMs = maxOf(nowMs, old.updatedAtMs))
            changed(replace(document, row))
        }
    }

    fun pause(identity: DownloadIdentity, nowMs: Long): DownloadResult = transition(identity, nowMs,
        setOf(DownloadState.QUEUED, DownloadState.DOWNLOADING)) { row, generation ->
        row.copy(state = DownloadState.PAUSED, generation = generation, lastSequence = 0, failure = null)
    }

    fun retry(identity: DownloadIdentity, nowMs: Long): DownloadResult = transition(identity, nowMs,
        setOf(DownloadState.PAUSED, DownloadState.FAILED, DownloadState.CANCELLED)) { row, generation ->
        row.copy(state = DownloadState.QUEUED, generation = generation, lastSequence = 0, failure = null,
            localMediaKey = null, bytesDownloaded = if (row.state == DownloadState.CANCELLED) 0 else row.bytesDownloaded,
            totalBytes = if (row.state == DownloadState.CANCELLED) 0 else row.totalBytes)
    }

    fun cancel(identity: DownloadIdentity, nowMs: Long): DownloadResult = transition(identity, nowMs,
        setOf(DownloadState.QUEUED, DownloadState.DOWNLOADING, DownloadState.PAUSED, DownloadState.FAILED)) { row, generation ->
        row.copy(state = DownloadState.CANCELLED, generation = generation, lastSequence = 0,
            bytesDownloaded = 0, totalBytes = 0, localMediaKey = null, failure = null)
    }

    fun fail(session: DownloadSession, kind: DownloadErrorKind, nowMs: Long): DownloadResult {
        if (nowMs < 0) return invalid()
        return mutate { document ->
            val row = current(document, session) ?: return@mutate unchanged(document)
            invalidate(document, row.copy(state = DownloadState.FAILED, failure = kind, localMediaKey = null,
                updatedAtMs = maxOf(nowMs, row.updatedAtMs)))
        }
    }

    /** The native adapter must verify bytes/package completeness before reporting completion. */
    fun complete(session: DownloadSession, localMediaKey: String, bytesDownloaded: Long, nowMs: Long): DownloadResult {
        if (!validLocalKey(localMediaKey) || bytesDownloaded <= 0 || nowMs < 0) return invalid()
        return mutate { document ->
            val row = current(document, session) ?: return@mutate unchanged(document)
            if (bytesDownloaded < row.bytesDownloaded || row.totalBytes > 0 && bytesDownloaded != row.totalBytes) return@mutate DownloadMutation(document, invalid(document.records))
            if (document.records.any { it.identity != row.identity && it.localMediaKey == localMediaKey }) return@mutate DownloadMutation(document, invalid(document.records))
            invalidate(document, row.copy(state = DownloadState.COMPLETED, localMediaKey = localMediaKey,
                bytesDownloaded = bytesDownloaded, totalBytes = bytesDownloaded, failure = null,
                updatedAtMs = maxOf(nowMs, row.updatedAtMs)))
        }
    }

    /** Missing/corrupt files are not silently retained as completed offline media. */
    fun markUnavailable(identity: DownloadIdentity, kind: DownloadErrorKind, nowMs: Long): DownloadResult {
        if (kind != DownloadErrorKind.MISSING && kind != DownloadErrorKind.CORRUPT) return invalid()
        return transition(identity, nowMs, setOf(DownloadState.COMPLETED)) { row, generation ->
            row.copy(state = DownloadState.FAILED, generation = generation, lastSequence = 0, failure = kind, localMediaKey = null)
        }
    }

    /** Recovery is explicit: active/queued rows become paused, never auto-start a stale source. */
    fun recoverInterrupted(nowMs: Long): DownloadResult {
        if (nowMs < 0) return invalid()
        return mutate { initial ->
            var document = initial
            for (row in initial.records.filter { it.state == DownloadState.DOWNLOADING || it.state == DownloadState.QUEUED }) {
                val result = invalidate(document, row.copy(state = DownloadState.PAUSED, failure = null,
                    updatedAtMs = maxOf(nowMs, row.updatedAtMs)))
                if (result.result.error != null) return@mutate result
                document = result.document
            }
            if (document == initial) unchanged(initial) else changed(document)
        }
    }

    /** Metadata removal only. Native code must cancel first and delete only its owned file. */
    fun remove(identity: DownloadIdentity): DownloadResult = mutate { document ->
        val row = document.records.firstOrNull { it.identity == identity } ?: return@mutate unchanged(document)
        if (row.state == DownloadState.DOWNLOADING) return@mutate DownloadMutation(document, DownloadResult(document.records, error = "Cancel the active transfer before removing metadata"))
        changed(document.copy(records = document.records.filterNot { it.identity == identity }))
    }

    private fun transition(identity: DownloadIdentity, nowMs: Long, allowed: Set<DownloadState>, transform: (DownloadRecord, Long) -> DownloadRecord): DownloadResult {
        if (!validIdentity(identity) || nowMs < 0) return invalid()
        return mutate { document ->
            val old = document.records.firstOrNull { it.identity == identity } ?: return@mutate unchanged(document)
            if (old.state !in allowed) return@mutate unchanged(document)
            if (document.nextGeneration == Long.MAX_VALUE) return@mutate exhausted(document)
            val row = transform(old, document.nextGeneration).copy(updatedAtMs = maxOf(nowMs, old.updatedAtMs))
            changed(replace(document.copy(nextGeneration = document.nextGeneration + 1), row))
        }
    }

    private fun current(document: DownloadDocument, session: DownloadSession): DownloadRecord? =
        document.records.firstOrNull { it.identity == session.identity && it.generation == session.generation && it.state == DownloadState.DOWNLOADING }
    private fun invalidate(document: DownloadDocument, row: DownloadRecord): DownloadMutation {
        if (document.nextGeneration == Long.MAX_VALUE) return exhausted(document)
        return changed(replace(document.copy(nextGeneration = document.nextGeneration + 1), row.copy(generation = document.nextGeneration, lastSequence = 0)))
    }
    private data class DownloadMutation(val document: DownloadDocument, val result: DownloadResult)
    private fun changed(document: DownloadDocument) = DownloadMutation(document, DownloadResult(document.records, accepted = true))
    private fun unchanged(document: DownloadDocument) = DownloadMutation(document, DownloadResult(document.records))
    private fun exhausted(document: DownloadDocument) = DownloadMutation(document, DownloadResult(document.records, error = "Download generation or queue counter exhausted"))
    private fun invalid(records: List<DownloadRecord> = emptyList()) = DownloadResult(records, error = "Invalid download operation")
    private fun replace(document: DownloadDocument, row: DownloadRecord) = document.copy(records = document.records.map { if (it.identity == row.identity) row else it })

    private fun mutate(transform: (DownloadDocument) -> DownloadMutation): DownloadResult {
        repeat(32) {
            val read = storage.read()
            if (read.error != null) return DownloadResult(error = read.error)
            val before = try { decode(read.content) } catch (_: InvalidDocument) {
                return DownloadResult(error = "Invalid download metadata; existing data preserved")
            }
            val after = transform(before)
            if (after.result.error != null || !after.result.accepted) return after.result
            val write = storage.compareAndSet(read.content, json.encodeToString(DownloadDocument.serializer(), after.document))
            if (write.error != null) return DownloadResult(before.records, error = write.error)
            if (write.written) return after.result
        }
        return DownloadResult(error = "Download metadata is busy; retry the operation")
    }

    private class InvalidDocument : Exception()
    private fun decode(content: String?): DownloadDocument {
        if (content == null) return DownloadDocument()
        return try {
            val root = json.parseToJsonElement(content).jsonObject
            if (root["version"]?.jsonPrimitive?.intOrNull != 1) throw InvalidDocument()
            val doc = json.decodeFromString(DownloadDocument.serializer(), content)
            if (doc.nextGeneration <= 0 || doc.nextQueueOrder <= 0 || doc.records.any { !validRecord(it, doc) } ||
                doc.records.distinctBy { it.identity }.size != doc.records.size ||
                doc.records.map { it.queueOrder }.distinct().size != doc.records.size ||
                doc.records.mapNotNull { it.localMediaKey }.distinct().size != doc.records.count { it.localMediaKey != null }) throw InvalidDocument()
            doc.copy(records = doc.records.sortedBy { it.queueOrder })
        } catch (_: SerializationException) { throw InvalidDocument() }
        catch (_: IllegalArgumentException) { throw InvalidDocument() }
    }
    private fun validRecord(row: DownloadRecord, doc: DownloadDocument): Boolean =
        validIdentity(row.identity) && validTitle(row.title) && validTitle(row.episodeTitle) && row.episodeNumber > 0 &&
            row.bytesDownloaded >= 0 && row.totalBytes >= 0 && (row.totalBytes == 0L || row.bytesDownloaded <= row.totalBytes) &&
            row.generation > 0 && row.generation < doc.nextGeneration && row.lastSequence >= 0 &&
            row.queueOrder > 0 && row.queueOrder < doc.nextQueueOrder && row.updatedAtMs >= 0 &&
            (row.localMediaKey == null || validLocalKey(row.localMediaKey)) &&
            ((row.state == DownloadState.COMPLETED) == (row.localMediaKey != null)) &&
            (row.state != DownloadState.COMPLETED || row.bytesDownloaded > 0 && row.totalBytes == row.bytesDownloaded) &&
            ((row.state == DownloadState.FAILED) == (row.failure != null))
    private fun validIdentity(identity: DownloadIdentity): Boolean = listOf(identity.providerId, identity.animeId, identity.episodeId).all { it.isNotBlank() && it.length <= 1024 }
    private fun validTitle(value: String) = value.isNotBlank() && value.length <= 4096
    private fun validLocalKey(value: String) = value.length in 1..128 && !value.contains("..") && Regex("^[A-Za-z0-9][A-Za-z0-9._-]*$").matches(value)
}
