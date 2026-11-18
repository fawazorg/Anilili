package com.anilili.provider

import com.anilili.catalog.*
import com.anilili.episodes.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import kotlin.test.*

class ExpandedProviderTest {
    private val json = Json
    private fun obj(body: String) = json.parseToJsonElement(body).jsonObject
    private val packages = """{"episodes":{"1":{"sub":true,"dub":true},"2":{"sub":true,"dub":false},"0":{"sub":true},"x":{},"3":null}}"""
    private val bootstrap = """{"effectiveLanguage":"sub","settlarSelection":"selection&+/?"}"""
    private val bridge = """{"embedUrl":"https://embed.settlar.io/player?t=token%2B%26%3D"}"""
    private val session = """{"source":"https://media.example/video.mp4","kind":"mp4","subtitles":[]}"""
    private fun repository(provider: String, transport: CatalogHttpTransport, timeoutMs: Long = 1000) =
        ExpandedProviderRepository(transport, provider, if (provider == "anipm") "https://ani.pm" else "https://anichan.to", "https://embed.settlar.io", timeoutMs)
    private fun success(body: String) = CatalogHttpResponse(200, body)
    private fun aniPmTransport(transform: (CatalogHttpRequest, String) -> CatalogHttpResponse = { _, body -> success(body) }) = CatalogHttpTransport { request ->
        val body = when {
            "_packages" in request.url -> packages
            "playback-bootstrap" in request.url -> bootstrap
            "/anime/settlar/session" in request.url -> bridge
            "/api/embed/session" in request.url -> session
            else -> error("Unexpected fixture request")
        }
        transform(request, body)
    }
    private fun aniChanTransport(transform: (CatalogHttpRequest, CatalogHttpResponse) -> CatalogHttpResponse = { _, response -> response }) = CatalogHttpTransport { request ->
        val response = when {
            "/site-config" in request.url -> success("""{"turnstileSiteKey":null}""")
            "/api/watch/session" in request.url -> CatalogHttpResponse(200, "{}", mapOf("Set-Cookie" to "anichan_ws=synthetic_fixture; Path=/; Secure"))
            "/api/watch/episodes" in request.url -> success("""{"episodes":2,"dubAvailable":true}""")
            "/api/watch/servers" in request.url -> success("""{"servers":[{"name":"anichan","rank":1,"stream":"https://media.example/master.m3u8"}]}""")
            else -> error("Unexpected fixture request")
        }
        transform(request, response)
    }

    @Test fun packageAvailabilityKeepsSeparateAudioAndStableProviderIds() = runTest {
        val repo = repository("anipm", aniPmTransport())
        assertEquals(listOf("anipm:sub:1", "anipm:sub:2"), repo.episodes(101, "sub").map { it.id })
        assertEquals(listOf("anipm:dub:1"), repo.episodes(101, "dub").map { it.id })
        assertTrue(repo.episodes(101, "sub").all { it.animeId == 101 })
    }
    @Test fun aniChanMapsCountAndDubWithoutTitleMatching() = runTest {
        val repo = repository("anichan", aniChanTransport())
        assertEquals(listOf(1, 2), repo.episodes(101, "dub").map { it.number })
        assertEquals("anichan:dub:1", repo.episodes(101, "dub").first().id)
    }
    @Test fun emptyAndMissingPackagesAreEmptyNotSyntheticEpisodes() = runTest {
        for (payload in listOf("{}", """{"episodes":{}}""")) {
            val repo = repository("anipm", CatalogHttpTransport { success(payload) })
            assertTrue(repo.episodes(101, "sub").isEmpty())
        }
    }
    @Test fun aniChanEmptyTitleRetainsOriginalFailureSemantics() = runTest {
        val repo = repository("anichan", CatalogHttpTransport { success("""{"episodes":0}""") })
        assertEquals(CatalogFailureKind.MALFORMED, assertFailsWith<CatalogException> { repo.episodes(101, "sub") }.failure.kind)
        assertFailsWith<IllegalStateException> { AniChanSharedParser.availability(obj("""{"episodes":0}""")) }
    }
    @Test fun sourceResolutionEscapesSelectionsAndTokensOnEveryHop() = runTest {
        val seen = mutableListOf<CatalogHttpRequest>()
        val repo = repository("anipm", aniPmTransport { request, body -> seen += request; success(body) })
        val source = repo.resolve(101, "anipm:sub:1", 1000)
        assertEquals(PlaybackFormat.MP4, source.format)
        assertEquals("anipm:sub:1", source.episodeId)
        assertTrue(seen[1].url.contains("selection=selection%26%2B%2F%3F"))
        assertTrue(seen[2].url.endsWith("t=token%2B%26%3D"))
        assertTrue(seen.all { it.method == "GET" && it.headers["User-Agent"] == ExpandedProviderRepository.USER_AGENT })
        assertEquals(setOf("User-Agent"), source.headers.keys)
    }
    @Test fun bootstrapNeverSilentlyFallsBackFromDubToSub() = runTest {
        val repo = repository("anipm", aniPmTransport())
        assertEquals(CatalogFailureKind.UNSUPPORTED, assertFailsWith<CatalogException> { repo.resolve(101, "anipm:dub:1", 1000) }.failure.kind)
    }
    @Test fun malformedMissingAndWrongShapeResponsesFail() = runTest {
        for (payload in listOf("broken", "[]", "null")) {
            val repo = repository("anipm", CatalogHttpTransport { success(payload) })
            assertEquals(CatalogFailureKind.MALFORMED, assertFailsWith<CatalogException> { repo.episodes(101, "sub") }.failure.kind)
        }
        val repo = repository("anipm", aniPmTransport { request, body -> success(if ("playback-bootstrap" in request.url) "{}" else body) })
        assertFailsWith<CatalogException> { repo.resolve(101, "anipm:sub:1", 1000) }
    }
    @Test fun httpErrorsRetainCodesWithoutRetryingAuthentication() = runTest {
        for (status in listOf(401, 403, 404, 429, 500, 503)) {
            var calls = 0
            val repo = repository("anipm", CatalogHttpTransport { calls++; CatalogHttpResponse(status, "private upstream payload") })
            val failure = assertFailsWith<CatalogException> { repo.episodes(101, "sub") }.failure
            assertEquals(status, failure.status); assertEquals(CatalogFailureKind.HTTP, failure.kind)
            assertEquals(1, calls); assertFalse(failure.message.contains("private"))
        }
    }
    @Test fun sessionCookieIsExplicitAndNeverCopiedToMedia() = runTest {
        val seen = mutableListOf<CatalogHttpRequest>()
        val repo = repository("anichan", aniChanTransport { request, response -> seen += request; response })
        val source = repo.resolve(101, "anichan:sub:1", 1000)
        assertEquals("POST", seen[1].method); assertEquals("{\"token\":\"\"}", seen[1].body)
        assertEquals("anichan_ws=synthetic_fixture", seen[2].headers["Cookie"])
        assertEquals("https://anichan.to/", seen[2].headers["Referer"])
        assertTrue(source.cookies.isEmpty()); assertFalse(source.headers.containsKey("Cookie"))
    }
    @Test fun serverUnauthorizedRenewsOnlyOnce() = runTest {
        var sessions = 0; var servers = 0
        val repo = repository("anichan", aniChanTransport { request, response ->
            if ("/watch/session" in request.url) sessions++
            if ("/watch/servers" in request.url) { servers++; CatalogHttpResponse(401, "{}") } else response
        })
        assertEquals(401, assertFailsWith<CatalogException> { repo.resolve(101, "anichan:sub:1", 1000) }.failure.status)
        assertEquals(2, sessions); assertEquals(2, servers)
    }
    @Test fun serverUnauthorizedCanRecoverWithOneFreshLegitimateSession() = runTest {
        var sessions = 0; var servers = 0
        val cookies = mutableListOf<String?>()
        val repo = repository("anichan", aniChanTransport { request, response ->
            when {
                "/watch/session" in request.url -> {
                    sessions++
                    CatalogHttpResponse(200, "{}", mapOf("Set-Cookie" to "anichan_ws=synthetic_session_$sessions; Path=/; Secure"))
                }
                "/watch/servers" in request.url -> {
                    servers++; cookies += request.headers["Cookie"]
                    if (servers == 1) CatalogHttpResponse(401, "{}") else response
                }
                else -> response
            }
        })
        val source = repo.resolve(101, "anichan:sub:1", 1000)
        assertEquals(PlaybackFormat.HLS, source.format)
        assertEquals(2, sessions); assertEquals(2, servers)
        assertEquals(listOf<String?>("anichan_ws=synthetic_session_1", "anichan_ws=synthetic_session_2"), cookies)
        assertTrue(source.cookies.isEmpty())
    }
    @Test fun malformedSessionTokenEncodingIsRejectedBeforeEmbedRequest() = runTest {
        var embedRequests = 0
        val repo = repository("anipm", aniPmTransport { request, body ->
            if ("/api/embed/session" in request.url) embedRequests++
            success(if ("/anime/settlar/session" in request.url)
                """{"embedUrl":"https://embed.settlar.io/player?t=%ZZ"}""" else body)
        })
        assertEquals(CatalogFailureKind.MALFORMED, assertFailsWith<CatalogException> {
            repo.resolve(101, "anipm:sub:1", 1000)
        }.failure.kind)
        assertEquals(0, embedRequests)
    }
    @Test fun browserVerificationIsRejectedBeforeSessionCreation() = runTest {
        var sessions = 0
        val repo = repository("anichan", aniChanTransport { request, response ->
            if ("/watch/session" in request.url) sessions++
            if ("site-config" in request.url) success("""{"turnstileSiteKey":"public-site-key"}""") else response
        })
        assertEquals(CatalogFailureKind.UNSUPPORTED, assertFailsWith<CatalogException> { repo.resolve(101, "anichan:sub:1", 1000) }.failure.kind)
        assertEquals(0, sessions)
    }
    @Test fun absentSessionCookieAndChallengeConfigAreMalformed() = runTest {
        for (dropConfig in listOf(true, false)) {
            val repo = repository("anichan", aniChanTransport { request, response ->
                if (dropConfig && "site-config" in request.url) success("{}")
                else if (!dropConfig && "/watch/session" in request.url) success("{}") else response
            })
            assertEquals(CatalogFailureKind.MALFORMED, assertFailsWith<CatalogException> { repo.resolve(101, "anichan:sub:1", 1000) }.failure.kind)
        }
    }
    @Test fun timeoutIsClassifiedAndCancellationRemainsCancellation() = runTest {
        val repo = repository("anipm", CatalogHttpTransport { awaitCancellation() }, 10)
        assertEquals(CatalogFailureKind.TIMEOUT, assertFailsWith<CatalogException> { repo.episodes(101, "sub") }.failure.kind)
        val started = CompletableDeferred<Unit>(); var cancelled = false
        val slow = repository("anipm", CatalogHttpTransport { started.complete(Unit); try { awaitCancellation() } finally { cancelled = true } })
        val job = launch { slow.episodes(101, "sub") }
        started.await(); job.cancelAndJoin(); assertTrue(cancelled)
    }
    @Test fun crossOriginRedirectsAreRejectedAndSameOriginFinalUrlAccepted() = runTest {
        val successRepo = repository("anipm", CatalogHttpTransport { CatalogHttpResponse(200, packages, emptyMap(), "https://ani.pm/final") })
        assertEquals(2, successRepo.episodes(101, "sub").size)
        val refused = repository("anipm", CatalogHttpTransport { CatalogHttpResponse(200, packages, emptyMap(), "https://unrelated.example/final") })
        assertEquals(CatalogFailureKind.UNSUPPORTED, assertFailsWith<CatalogException> { refused.episodes(101, "sub") }.failure.kind)
    }
    @Test fun sourceExpirationIsNotAcceptedEvenWithSuccessfulHttp() = runTest {
        val repo = repository("anipm", aniPmTransport { request, body -> success(if ("/api/embed/session" in request.url) """{"source":"https://media.example/video.mp4","kind":"mp4","expiresAtMs":1}""" else body) })
        assertEquals(CatalogFailureKind.EXPIRED, assertFailsWith<CatalogException> { repo.resolve(101, "anipm:sub:1", 1000) }.failure.kind)
    }
    @Test fun invalidIdentityAudioTimestampAndUnsupportedFormatAreExplicit() = runTest {
        val repo = repository("anipm", aniPmTransport())
        assertNull(repo.episodeAudio("anichan:sub:1")); assertEquals("dub", repo.episodeAudio("anipm:dub:2"))
        assertFailsWith<CatalogException> { repo.resolve(101, "anichan:sub:1", 1000) }
        assertFailsWith<CatalogException> { repo.resolve(101, "anipm:sub:1", -1) }
        assertFailsWith<CatalogException> { repo.episodes(101, "original") }
        assertFailsWith<CatalogException> { repo.episodes(-1, "sub") }
        val unsupported = repository("anipm", aniPmTransport { request, body ->
            success(if ("/api/embed/session" in request.url) body.replace("\"kind\":\"mp4\"", "\"kind\":\"dash\"") else body)
        })
        assertEquals(CatalogFailureKind.UNSUPPORTED, assertFailsWith<CatalogException> {
            unsupported.resolve(101, "anipm:sub:1", 1000)
        }.failure.kind)
    }
    @Test fun externalTrackConsentRemovesOnlyExternalSubtitles() {
        val repo = repository("anipm", aniPmTransport())
        val source = PlaybackSource("anipm:sub:1", "https://media.example/master.m3u8", PlaybackFormat.HLS,
            mapOf("User-Agent" to "fixture"), cookies = listOf(PlaybackCookie("session", "synthetic", "media.example")),
            expiresAtMs = 5000, audioTracks = listOf(PlaybackTrack("audio", "Audio", "en", "https://media.example/audio.m3u8")),
            subtitleTracks = listOf(PlaybackTrack("embedded", "English", "en"), PlaybackTrack("external", "French", "fr", "https://media.example/fr.vtt")),
            requirements = listOf("unsupported-test-requirement"))
        assertEquals(source.copy(subtitleTracks = source.subtitleTracks.take(1)), repo.videoWithoutExternalSubtitles(source))
    }
    @Test fun parsingPreservesRankingSpaceEncodingDefaultSubtitlesAndSkipWindows() {
        val root = obj("""{"servers":[{"name":"megaplay_hd1","stream":"https://bad.example/m.m3u8"},{"name":"other","rank":2,"stream":"https://media.example/other.m3u8"},{"name":"anichan","rank":1,"label":"★ Main","stream":"/master.m3u8","subtitles":[{"url":"/English (CR).vtt","lang":"English"}]}]}""")
        val parsed = AniChanSharedParser.sources(root["servers"]!!.jsonArray)
        assertEquals(listOf("Main", "other"), parsed.streams.map { it.quality })
        assertEquals("https://anichan.to/English%20(CR).vtt", parsed.subtitles.single().url)
        val skip = AniPmSharedParser.skip(obj("""{"skip":{"op":{"start":2,"end":90}}}"""))
        assertEquals(90.0, skip?.introEnd)
        assertNull(AniPmSharedParser.skip(obj("""{"skip":{}}""")))
        val tracks = AniPmSharedParser.sources(obj("""{"source":"https://media.example/master.m3u8","subtitles":[{"url":"https://media.example/th.vtt","srclang":"tha"},{"url":"https://media.example/en.vtt","srclang":"eng","default":true}]}"""), skip).subtitles
        assertEquals(listOf("en", "th"), tracks.map { it.language })
    }
    @Test fun callbackClientCancellationCancelsTransportAndSuppressesLateCompletion() = runTest {
        val started = CompletableDeferred<CatalogHttpCompletion>()
        val cancelled = CompletableDeferred<Unit>()
        val delivered = CompletableDeferred<Unit>()
        val client = ExpandedProviderClient(object : CatalogCallbackTransport {
            override fun post(request: CatalogHttpRequest, completion: CatalogHttpCompletion): CatalogCancellation {
                started.complete(completion)
                return object : CatalogCancellation { override fun cancel() { cancelled.complete(Unit) } }
            }
        }, "anipm")
        try {
            val handle = client.episodes(101, "sub", object : EpisodeListCompletion {
                override fun complete(episodes: List<Episode>?, failure: CatalogFailure?) { delivered.complete(Unit) }
            })
            // The facade owns Dispatchers.Default; use that context to await real callbacks rather
            // than advancing the test scheduler past a native transport that has not run yet.
            withContext(Dispatchers.Default) {
                val callback = withTimeout(5_000) { started.await() }
                handle.cancel()
                withTimeout(5_000) { cancelled.await() }
                callback.complete(success(packages), null)
            }
            assertFalse(delivered.isCompleted)
        } finally { client.close() }
    }

    @Test fun insecureLiveMediaRejectedButExplicitLoopbackFixtureAccepted() = runTest {
        assertFailsWith<IllegalStateException> { AniPmSharedParser.sources(obj("""{"source":"http://127.0.0.1:8765/progressive.mp4","kind":"mp4"}"""), null) }
        val repo = ExpandedProviderRepository(CatalogHttpTransport { request -> success(when {
            "playback-bootstrap" in request.url -> bootstrap
            "/anime/settlar/session" in request.url -> bridge
            else -> """{"source":"http://127.0.0.1:8765/progressive.mp4","kind":"mp4"}"""
        }) }, "anipm", "http://127.0.0.1:8765/provider/expanded/anipm", "http://127.0.0.1:8765/provider/expanded/anipm")
        assertEquals(PlaybackFormat.MP4, repo.resolve(101, "anipm:sub:1", 1000).format)
    }
}
