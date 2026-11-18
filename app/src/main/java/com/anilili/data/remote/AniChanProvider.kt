package com.anilili.data.remote

import com.anilili.data.model.Media
import com.anilili.data.model.SourcesResult
import com.anilili.data.model.StreamItem
import com.anilili.data.model.SubtitleItem
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * AniChan (anichan.to) — JSON throughout and keyed directly by AniList id, like [AniBdProvider],
 * so it needs no search request and no title matching: `media.id` is the lookup.
 *
 * ```
 * GET  /api/watch/episodes?anilistId=154587      -> {"episodes":28,"dubAvailable":true}   (~200ms)
 * POST /api/watch/session   {"token":""}         -> Set-Cookie: anichan_ws=…  Max-Age=7200
 * GET  /api/watch/servers?anilistId=&ep=&category= -> {"servers":[…]}                      (~700ms)
 * ```
 *
 * Its own server answers a **1080p** h264/AAC master with soft subtitles in a dozen languages, and
 * every URL measured — master, variant and segments — returned 206 with
 * `Access-Control-Allow-Origin: *` and no Referer, so [StreamItem.referer] is left null for the
 * same reason [AnimeHeavenProvider] leaves it null: that is what keeps a cast off `StreamCorsProxy`.
 *
 * Segments arrive as `.ts.png` / `.ts.webp` with an image content type. That is camouflage, not a
 * different container — the same trick AniKoto's CDN uses.
 */
internal class AniChanProvider(private val client: OkHttpClient, private val json: Json) {

    /**
     * The `anichan_ws` cookie `/api/watch/servers` demands, and when it stops being usable.
     *
     * `/api/watch/servers` answers `401 {"detail":"session"}` without it, and no combination of
     * browser headers or a cookie jar substitutes — the session is minted by an explicit POST.
     */
    private data class Session(val cookie: String, val expiresAtMs: Long)

    @Volatile
    private var session: Session? = null
    private val sessionLock = Any()

    fun episodeAvailability(media: Media): EpisodeAvailability {
        val root = getJson("$BASE/api/watch/episodes?anilistId=${media.id}", cookie = null).second
            ?: error("AniChan returned no episode payload")
        return AniChanParser.availability(root)
    }

    fun sources(media: Media, audio: String, episode: Int): SourcesResult {
        val category = if (audio.equals("dub", ignoreCase = true)) "dub" else "sub"
        return AniChanParser.sources(servers(media.id, episode, category))
    }

    private fun servers(anilistId: Int, episode: Int, category: String): JsonArray {
        val url = "$BASE/api/watch/servers?anilistId=$anilistId&ep=$episode&category=$category"
        var (code, body) = getJson(url, session())
        if (code == 401) {
            // The cookie outlives its 2h window silently, and the only way to learn that is to be
            // refused; the client-side clock is a hint, not the authority.
            synchronized(sessionLock) { session = null }
            val retried = getJson(url, session())
            code = retried.first
            body = retried.second
        }
        if (code != 200) error("AniChan HTTP $code for episode $episode")
        return (body?.get("servers") as? JsonArray) ?: JsonArray(emptyList())
    }

    /**
     * A live `anichan_ws` cookie, minted if the held one is missing or spent.
     *
     * The `token` is a Cloudflare Turnstile response, and the site currently publishes
     * `turnstileSiteKey: null` at `/site-config`, which is why an empty one is accepted. That is a
     * setting they can change: if it comes back, this POST starts failing and the provider needs a
     * Turnstile solve rather than a patch here.
     */
    private fun session(): String = synchronized(sessionLock) {
        session?.takeIf { System.currentTimeMillis() < it.expiresAtMs }?.let { return it.cookie }
        val request = Request.Builder()
            .url("$BASE/api/watch/session")
            .header("User-Agent", USER_AGENT)
            .header("Referer", "$BASE/")
            .post("""{"token":""}""".toRequestBody(JSON_MEDIA_TYPE))
            .build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) error("AniChan session refused with HTTP ${response.code}")
            val cookie = response.headers("Set-Cookie")
                .firstOrNull { it.startsWith("$SESSION_COOKIE=") }
                ?.substringBefore(';')
                ?: error("AniChan session response carried no $SESSION_COOKIE cookie")
            // The body's `exp` is in seconds; a minute of slack matches what the site's own client
            // subtracts, and the 401 retry above covers the case where it is wrong anyway.
            val expiry = runCatching {
                json.parseToJsonElement(response.body?.string().orEmpty()) as? JsonObject
            }.getOrNull()?.number("exp")?.times(1000)?.toLong()
            session = Session(cookie, (expiry ?: (System.currentTimeMillis() + DEFAULT_SESSION_MS)) - SESSION_SLACK_MS)
            cookie
        }
    }

    private fun getJson(url: String, cookie: String?): Pair<Int, JsonObject?> {
        val request = Request.Builder().url(url)
            .header("User-Agent", USER_AGENT)
            .header("Accept", "application/json")
            .header("Referer", "$BASE/")
            .apply { cookie?.let { header("Cookie", it) } }
            .get().build()
        client.newCall(request).execute().use { response ->
            val body = runCatching {
                json.parseToJsonElement(response.body?.string().orEmpty()) as? JsonObject
            }.getOrNull()
            return response.code to body
        }
    }

    private fun JsonObject.number(name: String): Double? = (this[name] as? JsonPrimitive)?.doubleOrNull

    private companion object {
        /** Shared with the parser, which needs it to absolutise the URLs the API returns. */
        const val BASE = AniChanParser.BASE
        const val SESSION_COOKIE = "anichan_ws"
        const val DEFAULT_SESSION_MS = 7_200_000L
        const val SESSION_SLACK_MS = 60_000L
        val JSON_MEDIA_TYPE = "application/json".toMediaType()
        const val USER_AGENT =
            "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"
    }
}

/** Android adapter delegates payload semantics to the shared parser. */
internal object AniChanParser {
    const val BASE = com.anilili.provider.AniChanSharedParser.BASE
    fun availability(root: JsonObject): EpisodeAvailability =
        com.anilili.provider.AniChanSharedParser.availability(root).let { EpisodeAvailability(it.sub, it.dub) }
    fun sources(servers: JsonArray): SourcesResult =
        com.anilili.provider.AniChanSharedParser.sources(servers).toAndroidSources()
}
