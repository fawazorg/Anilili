package com.anilili.episodes

import com.anilili.catalog.CatalogException
import com.anilili.catalog.CatalogFailure
import com.anilili.catalog.CatalogFailureKind
import com.anilili.catalog.CatalogHttpRequest
import com.anilili.catalog.CatalogHttpTransport
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

@Serializable
data class Episode(val id: String, val animeId: Int, val number: Int, val title: String)
@Serializable
enum class PlaybackFormat { MP4, HLS }
@Serializable
data class PlaybackSource(
    val episodeId: String,
    val url: String,
    val format: PlaybackFormat,
    val headers: Map<String, String> = emptyMap(),
)
@Serializable
private data class EpisodeListResponse(val episodes: List<Episode>)
@Serializable
private data class EpisodeSourceResponse(val source: PlaybackSource?)

/** A small provider boundary; platform adapters own HTTP, credentials and media objects. */
class EpisodeRepository(private val transport: CatalogHttpTransport, private val endpoint: String) {
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun episodes(animeId: Int): List<Episode> {
        if (animeId <= 0) throw invalid("Invalid anime identity")
        val body = post("episodes", animeId, null)
        val rows = decode { json.decodeFromString(EpisodeListResponse.serializer(), body) }.episodes
        if (rows.any { it.animeId != animeId || it.id.isBlank() || it.number <= 0 || it.title.isBlank() } ||
            rows.map { it.id }.distinct().size != rows.size || rows.map { it.number }.distinct().size != rows.size) {
            throw invalid("Invalid episode list")
        }
        return rows.sortedBy { it.number }
    }

    suspend fun resolve(animeId: Int, episodeId: String): PlaybackSource {
        if (animeId <= 0 || episodeId.isBlank()) throw invalid("Invalid episode identity")
        val body = post("resolve", animeId, episodeId)
        val source = decode { json.decodeFromString(EpisodeSourceResponse.serializer(), body) }.source
            ?: throw CatalogException(CatalogFailure(CatalogFailureKind.HTTP, 404, "No playable source for this episode"))
        if (source.episodeId != episodeId || !validSourceUrl(source.url) ||
            source.headers.any { (name, value) -> name.isBlank() || name.any { it <= ' ' || it == ':' || it >= '\u007f' } || value.any { it < ' ' || it == '\u007f' } }) {
            throw invalid("Invalid playback source")
        }
        return source
    }

    private suspend fun post(operation: String, animeId: Int, episodeId: String?): String {
        currentCoroutineContext().ensureActive()
        val payload = buildJsonObject {
            put("operation", operation)
            put("animeId", animeId)
            if (episodeId != null) put("episodeId", episodeId)
        }.toString()
        val response = transport.post(CatalogHttpRequest(endpoint, payload))
        currentCoroutineContext().ensureActive()
        if (response.status !in 200..299) {
            throw CatalogException(CatalogFailure(CatalogFailureKind.HTTP, response.status, "Episode provider HTTP ${response.status}"))
        }
        return response.body
    }

    private fun validSourceUrl(value: String): Boolean {
        if (value.any { it <= ' ' || it == '\\' }) return false
        // Bundled fixtures are explicit demo assets, never inferred from a live AniList title.
        if (value == "fixture://progressive.mp4" || value == "fixture://hls/master.m3u8" || value == "fixture://invalid.mp4") return true
        val match = Regex("^https?://([^/?#]+)(?:[/?#].*)?$").matchEntire(value) ?: return false
        val authority = match.groupValues[1]
        // No credentials, malformed port, or empty host may cross the provider boundary.
        val parts = Regex("^(\\[[0-9A-Fa-f:]+\\]|[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)(?::([0-9]{1,5}))?$").matchEntire(authority)
            ?: return false
        val port = parts.groupValues[2]
        return (port.isEmpty() || port.toInt() in 1..65535) &&
            (parts.groupValues[1].startsWith("[") || parts.groupValues[1].split('.').all { it.isNotEmpty() && !it.startsWith("-") && !it.endsWith("-") })
    }

    private inline fun <T> decode(block: () -> T): T = try { block() }
    catch (_: SerializationException) { throw invalid("Invalid episode provider response") }
    catch (_: IllegalArgumentException) { throw invalid("Invalid episode provider response") }

    private fun invalid(message: String) = CatalogException(CatalogFailure(CatalogFailureKind.MALFORMED, 0, message))
}
