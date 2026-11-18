package com.anilili.provider

import com.anilili.catalog.CatalogException
import com.anilili.catalog.CatalogFailure
import com.anilili.catalog.CatalogFailureKind
import com.anilili.episodes.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json

/** Actual AniDB App server response is {"link":"https://.../master.m3u8"}.
 * Optional fields describe controlled compatibility fixtures and future explicit requirements;
 * missing fields retain the existing header-free HLS contract. */
object AniDbSourceParser {
    private val json = Json { ignoreUnknownKeys = true }
    @Serializable
    private data class Response(
        val link: String,
        val format: String? = null,
        val headers: Map<String, String> = emptyMap(),
        val cookies: List<PlaybackCookie> = emptyList(),
        val redirectPolicy: PlaybackRedirectPolicy = PlaybackRedirectPolicy.SYSTEM,
        val expiresAtMs: Long? = null,
        val audioTracks: List<PlaybackTrack> = emptyList(),
        val subtitleTracks: List<PlaybackTrack> = emptyList(),
        val requirements: List<String> = emptyList(),
    )

    fun parse(body: String, episodeId: String, endpoint: String, nowMs: Long): PlaybackSource {
        if (episodeId.isBlank() || nowMs < 0) fail(CatalogFailureKind.MALFORMED, "Invalid resolution request")
        val response = try { json.decodeFromString(Response.serializer(), body) }
        catch (_: SerializationException) { fail(CatalogFailureKind.MALFORMED, "Invalid provider response") }
        catch (_: IllegalArgumentException) { fail(CatalogFailureKind.MALFORMED, "Invalid provider response") }
        val url = MediaSourcePolicy.resolveUrl(endpoint, response.link)
            ?: fail(CatalogFailureKind.MALFORMED, "Invalid provider media URL")
        if (!MediaSourcePolicy.validHeaders(response.headers)) fail(CatalogFailureKind.MALFORMED, "Invalid provider headers")
        if (response.expiresAtMs?.let { it <= nowMs } == true) fail(CatalogFailureKind.EXPIRED, "Playback source expired; resolve it again")
        val format = when (response.format?.uppercase()) {
            null -> if (url.substringBefore('?').substringBefore('#').endsWith(".mp4", true)) PlaybackFormat.MP4 else PlaybackFormat.HLS
            "MP4" -> PlaybackFormat.MP4
            "HLS" -> PlaybackFormat.HLS
            else -> fail(CatalogFailureKind.UNSUPPORTED, "Provider media format is unsupported")
        }
        val authority = url.substringAfter("://").substringBefore('/').substringBefore('?').substringBefore('#')
        val host = (if (authority.startsWith("[")) authority.substringBefore(']').removePrefix("[")
            else authority.substringBefore(':')).lowercase()
        for (cookie in response.cookies) {
            val domain = cookie.domain.removePrefix(".").lowercase()
            if (cookie.name.isBlank() || !MediaSourcePolicy.validHeaders(mapOf(cookie.name to cookie.value)) ||
                cookie.value.any { it in "\";,\\" } ||
                domain.isBlank() || (host != domain && !host.endsWith(".$domain")) ||
                !cookie.path.startsWith('/') || cookie.path.any { it < ' ' } ||
                cookie.expiresAtMs?.let { it <= nowMs } == true || (cookie.secure && !url.startsWith("https://"))) {
                fail(CatalogFailureKind.MALFORMED, "Provider cookies do not match the media origin")
            }
        }
        for (track in response.audioTracks + response.subtitleTracks) {
            if (track.id.isBlank() || track.label.isBlank() || (track.url != null && !MediaSourcePolicy.validUrl(track.url))) {
                fail(CatalogFailureKind.MALFORMED, "Invalid provider track metadata")
            }
        }
        return PlaybackSource(episodeId, url, format, response.headers, response.cookies,
            response.redirectPolicy, response.expiresAtMs, response.audioTracks, response.subtitleTracks, response.requirements)
    }

    private fun fail(kind: CatalogFailureKind, message: String): Nothing =
        throw CatalogException(CatalogFailure(kind, 0, message))
}
