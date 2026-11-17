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
    val cookies: List<PlaybackCookie> = emptyList(),
    val redirectPolicy: PlaybackRedirectPolicy = PlaybackRedirectPolicy.SYSTEM,
    val expiresAtMs: Long? = null,
    val audioTracks: List<PlaybackTrack> = emptyList(),
    val subtitleTracks: List<PlaybackTrack> = emptyList(),
    val requirements: List<String> = emptyList(),
) {
    constructor(episodeId: String, url: String, format: PlaybackFormat, headers: Map<String, String>) :
        this(episodeId, url, format, headers, emptyList(), PlaybackRedirectPolicy.SYSTEM, null, emptyList(), emptyList(), emptyList())
}
@Serializable
data class PlaybackCookie(val name: String, val value: String, val domain: String,
    val path: String = "/", val secure: Boolean = true, val expiresAtMs: Long? = null)
@Serializable
enum class PlaybackRedirectPolicy { SYSTEM, SAME_ORIGIN, DENY }
@Serializable
data class PlaybackTrack(val id: String, val label: String, val language: String? = null, val url: String? = null)
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
        if (source.episodeId != episodeId || !com.anilili.provider.MediaSourcePolicy.validUrl(source.url, allowFixtures = true) ||
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

    private inline fun <T> decode(block: () -> T): T = try { block() }
    catch (_: SerializationException) { throw invalid("Invalid episode provider response") }
    catch (_: IllegalArgumentException) { throw invalid("Invalid episode provider response") }

    private fun invalid(message: String) = CatalogException(CatalogFailure(CatalogFailureKind.MALFORMED, 0, message))
}
