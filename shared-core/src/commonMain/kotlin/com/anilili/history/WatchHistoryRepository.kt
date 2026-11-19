package com.anilili.history

import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive

@Serializable
data class WatchIdentity(val providerId: String, val animeId: String, val episodeId: String)
@Serializable
data class WatchProgress(
    val identity: WatchIdentity,
    val title: String,
    val episodeTitle: String,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val completed: Boolean = false,
    val updatedAtMs: Long = 0,
    val generation: Long = 0,
    val lastSequence: Long = 0,
)
data class WatchSession(val identity: WatchIdentity, val generation: Long)
data class WatchHistoryRules(
    val completionPercent: Int = 90,
    val minDurationMs: Long = 60_000,
    val resumeRewindMs: Long = 3_000,
    val saveIntervalMs: Long = 10_000,
)
data class HistoryStorageRead(val content: String?, val error: String? = null)
data class HistoryStorageWrite(val written: Boolean, val error: String? = null)

/** compareAndSet must atomically compare persisted contents and replace them durably.
 * All adapters for the same storage path must coordinate through the same lock/transaction. */
interface WatchHistoryStorage {
    fun read(): HistoryStorageRead
    fun compareAndSet(expected: String?, updated: String): HistoryStorageWrite
}
data class HistoryResult(
    val records: List<WatchProgress> = emptyList(),
    val session: WatchSession? = null,
    val accepted: Boolean = false,
    val error: String? = null,
)
@Serializable
private data class HistoryDocument(val version: Int = 1, val records: List<WatchProgress> = emptyList())

/** One local history repository, portable domain decisions and transactional platform storage.
 * No in-memory record cache: recreation and concurrent repository instances see durable state. */
class WatchHistoryRepository(private val storage: WatchHistoryStorage, private val rules: WatchHistoryRules) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun snapshot(): HistoryResult {
        val read = storage.read()
        if (read.error != null) return HistoryResult(error = read.error)
        return decode(read.content)
    }

    fun continueWatching(): HistoryResult {
        val snapshot = snapshot()
        return snapshot.copy(records = snapshot.records.filter { !it.completed && it.positionMs > 0 })
    }

    fun resumePosition(record: WatchProgress): Long = WatchProgressPolicy.resumePositionMs(
        record.positionMs, record.durationMs, record.completed, rules.resumeRewindMs, true,
    )

    fun beginSession(identity: WatchIdentity, title: String, episodeTitle: String, nowMs: Long): HistoryResult {
        if (!validIdentity(identity) || nowMs < 0) return HistoryResult(error = "Invalid watch session")
        return mutate { records ->
            val old = records.firstOrNull { it.identity == identity }
            if (old?.generation == Long.MAX_VALUE) return@mutate HistoryResult(records, error = "History session counter exhausted")
            val generation = (old?.generation ?: 0) + 1
            val row = (old ?: WatchProgress(identity, title, episodeTitle)).copy(
                title = title, episodeTitle = episodeTitle,
                positionMs = if (old?.completed == true) 0 else old?.positionMs ?: 0,
                completed = old?.completed ?: false, updatedAtMs = old?.updatedAtMs ?: 0,
                generation = generation, lastSequence = 0,
            )
            HistoryResult(replace(records, row), WatchSession(identity, generation), true)
        }
    }

    fun update(session: WatchSession, positionMs: Double, durationMs: Double, nowMs: Long, sequence: Long): HistoryResult {
        if (!positionMs.isFinite() || positionMs < 0 || positionMs >= Long.MAX_VALUE.toDouble() ||
            !durationMs.isFinite() || durationMs < 0 || durationMs >= Long.MAX_VALUE.toDouble() || nowMs < 0 || sequence <= 0) {
            return HistoryResult(error = "Invalid playback progress")
        }
        return mutate { records ->
            val old = records.firstOrNull { it.identity == session.identity }
            if (old == null || old.generation != session.generation || sequence <= old.lastSequence || nowMs < old.updatedAtMs) {
                return@mutate HistoryResult(records)
            }
            val duration = durationMs.toLong()
            val position = positionMs.toLong().let { if (duration > 0) it.coerceAtMost(duration) else it }
            val completed = old.completed || (duration >= rules.minDurationMs.coerceAtLeast(1) && duration > 0 &&
                position > 0 && position.toDouble() / duration >= rules.completionPercent.coerceIn(1, 100) / 100.0)
            HistoryResult(replace(records, old.copy(positionMs = position, durationMs = duration,
                completed = completed, updatedAtMs = nowMs, lastSequence = sequence)), accepted = true)
        }
    }

    fun mark(identity: WatchIdentity, title: String, episodeTitle: String, watched: Boolean, nowMs: Long): HistoryResult {
        if (!validIdentity(identity) || nowMs < 0) return HistoryResult(error = "Invalid watch identity")
        return mutate { records ->
            val old = records.firstOrNull { it.identity == identity } ?: WatchProgress(identity, title, episodeTitle)
            if (old.generation == Long.MAX_VALUE) return@mutate HistoryResult(records, error = "History session counter exhausted")
            HistoryResult(replace(records, old.copy(title = title, episodeTitle = episodeTitle,
                positionMs = if (watched) old.durationMs else 0, completed = watched,
                updatedAtMs = maxOf(nowMs, old.updatedAtMs), generation = old.generation + 1, lastSequence = 0)), accepted = true)
        }
    }

    private fun mutate(transform: (List<WatchProgress>) -> HistoryResult): HistoryResult {
        repeat(32) {
            val read = storage.read()
            if (read.error != null) return HistoryResult(error = read.error)
            val before = decode(read.content)
            if (before.error != null) return before
            val after = transform(before.records)
            if (after.error != null || !after.accepted) return after
            val write = storage.compareAndSet(read.content, json.encodeToString(HistoryDocument.serializer(), HistoryDocument(records = after.records)))
            if (write.error != null) return before.copy(error = write.error)
            if (write.written) return after
        }
        return HistoryResult(error = "History storage is busy; retry the update")
    }

    private fun decode(content: String?): HistoryResult {
        if (content == null) return HistoryResult()
        return try {
            val root = json.parseToJsonElement(content).jsonObject
            if (root["version"]?.jsonPrimitive?.intOrNull != 1) return HistoryResult(error = "Unsupported history schema; existing data preserved")
            val document = json.decodeFromString(HistoryDocument.serializer(), content)
            if (document.records.any { !validIdentity(it.identity) || it.positionMs < 0 || it.durationMs < 0 || it.updatedAtMs < 0 || it.generation < 0 || it.lastSequence < 0 }) {
                return HistoryResult(error = "Invalid history data; existing data preserved")
            }
            val records = document.records
                .sortedWith(compareByDescending<WatchProgress> { it.updatedAtMs }.thenByDescending { it.generation }.thenByDescending { it.lastSequence })
                .distinctBy { it.identity }
            HistoryResult(records)
        } catch (_: SerializationException) { HistoryResult(error = "Corrupt history data; existing data preserved") }
        catch (_: IllegalArgumentException) { HistoryResult(error = "Corrupt history data; existing data preserved") }
    }

    private fun replace(records: List<WatchProgress>, row: WatchProgress): List<WatchProgress> =
        WatchProgressPolicy.latestFirst(listOf(row) + records.filterNot { it.identity == row.identity }) { it.updatedAtMs }
    private fun validIdentity(identity: WatchIdentity): Boolean =
        identity.providerId.isNotBlank() && identity.animeId.isNotBlank() && identity.episodeId.isNotBlank()
}
