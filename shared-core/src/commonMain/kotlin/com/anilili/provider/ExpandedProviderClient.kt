package com.anilili.provider

import com.anilili.catalog.*
import com.anilili.episodes.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.time.TimeSource

/** AniList supplies metadata; these existing providers supply real episode availability and media. */
class ExpandedProviderRepository(
    private val transport: CatalogHttpTransport,
    private val providerId: String,
    private val baseUrl: String = if (providerId == "anipm") "https://ani.pm" else "https://anichan.to",
    private val embedBaseUrl: String = "https://embed.settlar.io",
    private val timeoutMs: Long = 30_000,
) {
    private val json = Json { ignoreUnknownKeys = true }
    private val sessionMutex = Mutex()
    private val fixtureMode = localFixtureUrl(baseUrl)
    private val headers = mapOf("User-Agent" to USER_AGENT, "Accept" to "application/json")

    init {
        require(providerId == "anipm" || providerId == "anichan")
        require(validEndpoint(baseUrl) && validEndpoint(embedBaseUrl))
        require(!baseUrl.contains('?') && !baseUrl.contains('#') && !embedBaseUrl.contains('?') && !embedBaseUrl.contains('#'))
    }

    suspend fun episodes(animeId: Int, audio: String): List<Episode> = bounded {
        validateAnime(animeId)
        val channel = channel(audio)
        val availability = when (providerId) {
            "anipm" -> AniPmSharedParser.availability(objectResponse(request("$baseUrl/api/anime/anipm-server/_packages?anilistId=$animeId")))
            else -> {
                val root = objectResponse(request("$baseUrl/api/watch/episodes?anilistId=$animeId"))
                val count = (root["episodes"] as? JsonPrimitive)?.doubleOrNull
                if (count != null && (!count.isFinite() || count > 10_000)) throw malformed("Invalid provider episode count")
                AniChanSharedParser.availability(root)
            }
        }
        (if (channel == "dub") availability.dub else availability.sub).sorted().map {
            Episode("$providerId:$channel:$it", animeId, it, "Episode $it · ${channel.uppercase()}")
        }
    }

    suspend fun resolve(animeId: Int, episodeId: String, nowMs: Long): PlaybackSource = bounded {
        validateAnime(animeId)
        if (nowMs < 0) throw malformed("Invalid resolution timestamp")
        val started = TimeSource.Monotonic.markNow()
        val identity = identity(episodeId) ?: throw malformed("Invalid provider episode identity")
        val audio = identity.first; val episode = identity.second
        val parsed: ParsedProviderSources
        var expiresAtMs: Long? = null
        if (providerId == "anipm") {
            val bootstrap = objectResponse(request("$baseUrl/api/anime/playback-bootstrap/anilist/$animeId?ep=$episode&lang=$audio&core=0"))
            if (bootstrap.text("effectiveLanguage") != audio) throw failure(CatalogFailureKind.UNSUPPORTED, 0, "Requested audio is unavailable")
            val selection = bootstrap.text("settlarSelection")?.takeIf { it.isNotBlank() } ?: throw malformed("Provider offered no selection")
            val bridge = objectResponse(request("$baseUrl/api/anime/settlar/session?selection=${encode(selection)}&provider=anipm&ep=$episode&channel=$audio&telemetry=0"))
            val embed = bridge.text("embedUrl") ?: throw malformed("Provider offered no session")
            if (!validEndpoint(embed)) throw malformed("Invalid provider session URL")
            val token = queryValue(embed, "t")?.takeIf { it.isNotBlank() } ?: throw malformed("Provider offered no session token")
            val session = objectResponse(request("$embedBaseUrl/api/embed/session?t=${encode(token)}"))
            expiresAtMs = (session["expiresAtMs"] as? JsonPrimitive)?.longOrNull
            parsed = AniPmSharedParser.sources(session, AniPmSharedParser.skip(bootstrap), fixtureMode)
        } else {
            // Session cookies are per resolution: avoid retaining credentials or allowing obsolete
            // sessions to race renewal. Authentication failures are never retried indefinitely.
            parsed = sessionMutex.withLock {
                var cookie = createAniChanSession()
                val url = "$baseUrl/api/watch/servers?anilistId=$animeId&ep=$episode&category=$audio"
                var response = request(url, extraHeaders = mapOf("Cookie" to cookie), permit401 = true)
                if (response.status == 401) {
                    cookie = createAniChanSession()
                    response = request(url, extraHeaders = mapOf("Cookie" to cookie))
                }
                val root = objectResponse(response)
                expiresAtMs = (root["expiresAtMs"] as? JsonPrimitive)?.longOrNull
                val servers = root["servers"] as? JsonArray ?: throw malformed("Invalid provider server response")
                AniChanSharedParser.sources(servers, baseUrl)
            }
        }
        val first = parsed.streams.firstOrNull() ?: throw malformed("Provider offered no playable source")
        val format = when (first.type.lowercase()) {
            "hls", "m3u8" -> PlaybackFormat.HLS
            "mp4" -> PlaybackFormat.MP4
            else -> throw failure(CatalogFailureKind.UNSUPPORTED, 0, "Provider media format is unsupported")
        }
        if (!validEndpoint(first.url) || !MediaSourcePolicy.validUrl(first.url)) throw malformed("Invalid provider media URL")
        if (parsed.subtitles.any { it.url?.let { url -> !validEndpoint(url) } == true }) throw malformed("Invalid provider subtitle URL")
        if (expiresAtMs?.let { it <= nowMs + started.elapsedNow().inWholeMilliseconds.coerceAtMost(Long.MAX_VALUE - nowMs) } == true) throw failure(CatalogFailureKind.EXPIRED, 0, "Provider source expired; resolve again")
        PlaybackSource(episodeId, first.url, format, mapOf("User-Agent" to USER_AGENT),
            expiresAtMs = expiresAtMs, subtitleTracks = parsed.subtitles)
    }

    /** Explicit UI consent may omit external subtitles; no other capability is discarded. */
    fun videoWithoutExternalSubtitles(source: PlaybackSource): PlaybackSource =
        source.copy(subtitleTracks = source.subtitleTracks.filter { it.url == null })

    fun episodeAudio(episodeId: String): String? = identity(episodeId)?.first

    private suspend fun createAniChanSession(): String {
        val config = objectResponse(request("$baseUrl/site-config"))
        if (!config.containsKey("turnstileSiteKey")) throw malformed("Provider challenge configuration is unavailable")
        if (config["turnstileSiteKey"] != JsonNull) throw failure(CatalogFailureKind.UNSUPPORTED, 0, "Provider requires browser verification")
        val response = request("$baseUrl/api/watch/session", "POST", "{\"token\":\"\"}", mapOf("Content-Type" to "application/json"))
        val setCookie = response.headers.entries.firstOrNull { it.key.equals("Set-Cookie", true) }?.value
            ?: throw malformed("Provider session cookie is missing")
        val value = Regex("(?:^|,\\s*)anichan_ws=([^;,\\s]+)").find(setCookie)?.groupValues?.get(1)
            ?.takeIf { it.length <= 4096 && it.all { c -> c.code in 0x21..0x7e } }
            ?: throw malformed("Provider session cookie is invalid")
        return "anichan_ws=$value"
    }

    private suspend fun request(url: String, method: String = "GET", body: String = "", extraHeaders: Map<String, String> = emptyMap(), permit401: Boolean = false): CatalogHttpResponse {
        currentCoroutineContext().ensureActive()
        val response = transport.post(CatalogHttpRequest(url, body, method,
            headers + if (providerId == "anichan") mapOf("Referer" to "$baseUrl/") + extraHeaders else extraHeaders))
        currentCoroutineContext().ensureActive()
        // A native transport can follow normal redirects. Session credentials are never accepted
        // from an unrelated final origin; the native adapter strips cross-origin request headers.
        response.finalUrl?.let { if (origin(it) != origin(url)) throw failure(CatalogFailureKind.UNSUPPORTED, 0, "Cross-origin provider redirect is unsupported") }
        if (response.status !in 200..299 && !(permit401 && response.status == 401)) {
            throw failure(CatalogFailureKind.HTTP, response.status, "Provider HTTP ${response.status}")
        }
        return response
    }

    private fun objectResponse(response: CatalogHttpResponse): JsonObject =
        try { json.parseToJsonElement(response.body) as? JsonObject ?: throw malformed("Invalid provider response") }
        catch (error: CatalogException) { throw error }
        catch (_: Exception) { throw malformed("Invalid provider response") }

    private suspend fun <T> bounded(block: suspend () -> T): T = try {
        withTimeout(timeoutMs.coerceIn(1, 60_000)) { block() }
    } catch (error: TimeoutCancellationException) {
        currentCoroutineContext().ensureActive()
        throw failure(CatalogFailureKind.TIMEOUT, 0, "Provider request timed out")
    } catch (error: CancellationException) { throw error }
    catch (error: CatalogException) { throw error }
    catch (_: IllegalStateException) { throw malformed("Provider response has no usable media") }
    catch (_: IllegalArgumentException) { throw malformed("Invalid provider response") }
    catch (_: Exception) { throw failure(CatalogFailureKind.TRANSPORT, 0, "Provider request failed") }

    private fun identity(id: String): Pair<String, Int>? {
        val match = Regex("^${providerId}:(sub|dub):([1-9][0-9]*)$").matchEntire(id) ?: return null
        return match.groupValues[2].toIntOrNull()?.let { match.groupValues[1] to it }
    }
    private fun channel(audio: String) = audio.takeIf { it == "sub" || it == "dub" } ?: throw malformed("Invalid audio selection")
    private fun validateAnime(animeId: Int) { if (animeId <= 0) throw malformed("Invalid anime identity") }
    private fun validEndpoint(url: String) = MediaSourcePolicy.validUrl(url) && (url.startsWith("https://") || fixtureMode && localFixtureUrl(url))
    private fun origin(url: String) = Regex("^https?://[^/?#]+").find(url)?.value?.lowercase()
    private fun malformed(message: String) = failure(CatalogFailureKind.MALFORMED, 0, message)
    private fun failure(kind: CatalogFailureKind, status: Int, message: String) = CatalogException(CatalogFailure(kind, status, message))

    private fun queryValue(url: String, name: String): String? = url.substringAfter('?', "").substringBefore('#').split('&')
        .firstOrNull { it.substringBefore('=') == name }?.substringAfter('=', "")?.let(::decode)
    private fun encode(value: String): String = buildString {
        for (byte in value.encodeToByteArray()) {
            val code = byte.toInt() and 255
            if (code in 65..90 || code in 97..122 || code in 48..57 || code.toChar() in "-._~") append(code.toChar())
            else { append('%'); append("0123456789ABCDEF"[code shr 4]); append("0123456789ABCDEF"[code and 15]) }
        }
    }
    private fun decode(value: String): String {
        val bytes = mutableListOf<Byte>(); var index = 0
        while (index < value.length) {
            if (value[index] == '%') {
                if (index + 2 >= value.length) throw malformed("Invalid provider token encoding")
                val hex = value.substring(index + 1, index + 3).toIntOrNull(16) ?: throw malformed("Invalid provider token encoding")
                bytes += hex.toByte(); index += 3
            } else {
                bytes.addAll(value[index].toString().encodeToByteArray().toList()); index++
            }
        }
        return bytes.toByteArray().decodeToString(throwOnInvalidSequence = true)
    }

    companion object {
        const val USER_AGENT = "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Mobile Safari/537.36"
    }
}

/** Swift owns request lifecycle and native HTTP execution; Kotlin owns provider orchestration. */
class ExpandedProviderClient(transport: CatalogCallbackTransport, providerId: String, baseUrl: String, embedBaseUrl: String, timeoutMs: Long) {
    constructor(transport: CatalogCallbackTransport, providerId: String) : this(transport, providerId,
        if (providerId == "anipm") "https://ani.pm" else "https://anichan.to", "https://embed.settlar.io", 30_000)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val repository = ExpandedProviderRepository(CatalogHttpTransport { request ->
        suspendCancellableCoroutine { continuation ->
            val handle = transport.post(request, object : CatalogHttpCompletion {
                override fun complete(response: CatalogHttpResponse?, error: String?) {
                    if (response == null || error != null) continuation.resumeWithException(CatalogException(
                        CatalogFailure(CatalogFailureKind.TRANSPORT, 0, "Provider request failed")))
                    else continuation.resume(response)
                }
            })
            continuation.invokeOnCancellation { handle.cancel() }
        }
    }, providerId, baseUrl, embedBaseUrl, timeoutMs)

    fun episodes(animeId: Int, audio: String, completion: EpisodeListCompletion): CatalogCancellation = launch(
        { repository.episodes(animeId, audio) }, { completion.complete(it, null) }, { completion.complete(null, it) })
    fun resolve(animeId: Int, episodeId: String, nowMs: Long, completion: EpisodeSourceCompletion): CatalogCancellation = launch(
        { repository.resolve(animeId, episodeId, nowMs) }, { completion.complete(it, null) }, { completion.complete(null, it) })
    fun videoWithoutExternalSubtitles(source: PlaybackSource): PlaybackSource = repository.videoWithoutExternalSubtitles(source)
    fun episodeAudio(episodeId: String): String? = repository.episodeAudio(episodeId)
    fun close() { scope.cancel() }

    private fun <T> launch(block: suspend () -> T, success: (T) -> Unit, failed: (CatalogFailure) -> Unit): CatalogCancellation {
        val job = scope.launch {
            val result = try { block() }
            catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                ensureActive()
                failed((error as? CatalogException)?.failure ?: CatalogFailure(CatalogFailureKind.TRANSPORT, 0, "Provider request failed"))
                return@launch
            }
            ensureActive(); success(result)
        }
        return object : CatalogCancellation { override fun cancel() { job.cancel() } }
    }
}
