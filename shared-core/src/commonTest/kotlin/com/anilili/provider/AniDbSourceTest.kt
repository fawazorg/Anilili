package com.anilili.provider

import com.anilili.catalog.*
import com.anilili.episodes.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class AniDbSourceTest {
    private val endpoint = "https://api.example.invalid/episode/12/jpn/iframe"
    private fun parse(body: String, base: String = endpoint) = AniDbSourceParser.parse(body, "12/jpn", base, 1_000)

    @Test fun actualAnidbResponsePreservesHeaderFreeHlsContract() {
        val source = parse("""{"link":"https://media.example.invalid/master.m3u8","future":true}""")
        assertEquals("12/jpn", source.episodeId)
        assertEquals(PlaybackFormat.HLS, source.format)
        assertTrue(source.headers.isEmpty())
        assertTrue(source.cookies.isEmpty())
        assertEquals(PlaybackRedirectPolicy.SYSTEM, source.redirectPolicy)
        assertNull(MediaSourcePolicy.appleUnsupportedReason(source, 1_000))
    }

    @Test fun progressiveMetadataCookiesAndExpirationArePortable() {
        val source = parse("""{"link":"https://media.example.invalid/film.mp4?signature=private","expiresAtMs":2000,"headers":{"User-Agent":"Fixture/1"},"cookies":[{"name":"session","value":"private","domain":"media.example.invalid","path":"/"}],"audioTracks":[{"id":"audio-en","label":"English","language":"en"}],"subtitleTracks":[{"id":"subs-en","label":"English","language":"en","url":"https://media.example.invalid/en.vtt"}]}""")
        assertEquals(PlaybackFormat.MP4, source.format)
        assertEquals(2_000, source.expiresAtMs)
        assertEquals("private", source.cookies.single().value)
        assertEquals("en", source.subtitleTracks.single().language)
        assertNotNull(MediaSourcePolicy.appleUnsupportedReason(source, 1_000), "External tracks need a native adapter")
        assertNotNull(MediaSourcePolicy.appleUnsupportedReason(source, 2_000))
    }

    @Test fun relativeAndSignedLinksResolveWithoutDestroyingQueries() {
        assertEquals("https://api.example.invalid/episode/12/master.m3u8?token=a%2Fb", parse("""{"link":"../master.m3u8?token=a%2Fb"}""").url)
        assertEquals("https://api.example.invalid/hls/master.m3u8", parse("""{"link":"/hls/master.m3u8"}""").url)
        assertEquals("https://media.example.invalid/master.m3u8", parse("""{"link":"//media.example.invalid/master.m3u8"}""").url)
        assertEquals("https://cdn.example.invalid/a//b/?signed=a%2Fb", MediaSourcePolicy.resolveUrl("https://cdn.example.invalid/a//b/", "?signed=a%2Fb"))
        assertEquals("https://cdn.example.invalid/a//b/#track", MediaSourcePolicy.resolveUrl("https://cdn.example.invalid/a//b/", "#track"))
        assertEquals("https://cdn.example.invalid/a//master/", MediaSourcePolicy.resolveUrl("https://cdn.example.invalid/a//b/source", "../master/"))
        assertEquals("https://api.example.invalid/episode/12/jpn/iframe?q=1", parse("""{"link":"?q=1"}""").url)
    }

    @Test fun explicitUnsupportedRequirementsNeverLookPlayableOnApple() {
        for (body in listOf(
            """{"link":"https://media.example.invalid/master.m3u8","headers":{"Referer":"https://example.invalid"}}""",
            """{"link":"https://media.example.invalid/master.m3u8","requirements":["drm"]}""",
            """{"link":"https://media.example.invalid/master.m3u8","redirectPolicy":"DENY"}""",
        )) assertNotNull(MediaSourcePolicy.appleUnsupportedReason(parse(body), 1_000))
    }

    @Test fun malformedPrivateAndExpiredSourcesHaveSanitizedTypedErrors() {
        for (body in listOf("not json", "{}", "[]", """{"link":"javascript:private"}""", """{"link":"https://secret:private@example.invalid/a.m3u8"}""",
            """{"link":"https://media.example.invalid/a.m3u8","headers":{"X-Test":"private\r\nInjected: true"}}""",
            """{"link":"https://media.example.invalid/a.m3u8","cookies":[{"name":"session","value":"private","domain":"other.example.invalid"}]}""")) {
            val error = assertFailsWith<CatalogException> { parse(body) }
            assertEquals(CatalogFailureKind.MALFORMED, error.failure.kind)
            assertFalse(error.message.orEmpty().contains("private"))
        }
        assertEquals(CatalogFailureKind.EXPIRED, assertFailsWith<CatalogException> {
            parse("""{"link":"https://media.example.invalid/a.m3u8","expiresAtMs":999}""")
        }.failure.kind)
        assertEquals(CatalogFailureKind.UNSUPPORTED, assertFailsWith<CatalogException> {
            parse("""{"link":"https://media.example.invalid/a.mpd","format":"DASH"}""")
        }.failure.kind)
    }

    @Test fun validUrlPolicyIsSharedWithEpisodeResolution() {
        assertTrue(MediaSourcePolicy.validUrl("http://127.0.0.1:8765/a.mp4"))
        assertTrue(MediaSourcePolicy.validUrl("fixture://progressive.mp4", true))
        assertFalse(MediaSourcePolicy.validUrl("fixture://progressive.mp4"))
        for (url in listOf("https://:80/a", "http://example.invalid:99999/a", "https://private@example.invalid/a", "https://a..invalid/a")) {
            assertFalse(MediaSourcePolicy.validUrl(url))
        }
    }

    @Test fun networkContractUsesGetAndFinalRedirectUrlForRelativeSources() = runTest {
        var request: CatalogHttpRequest? = null
        val resolver = AniDbSourceResolver(CatalogHttpTransport {
            request = it
            CatalogHttpResponse(200, """{"link":"../media/master.m3u8"}""", emptyMap(), "https://final.example.invalid/api/source")
        })
        assertEquals("https://final.example.invalid/media/master.m3u8", resolver.resolve(endpoint, "12/jpn", 1_000).url)
        assertEquals("GET", request?.method)
        assertEquals("application/json", request?.headers?.get("Accept"))
        assertEquals("", request?.body)
        assertEquals("POST", CatalogHttpRequest(endpoint, "{}").method)
    }

    @Test fun authAndMissingResponsesAreNeverRetried() = runTest {
        for (status in listOf(401, 403, 404)) {
            var calls = 0
            val resolver = AniDbSourceResolver(CatalogHttpTransport { calls++; CatalogHttpResponse(status, "secret") }, retryDelayMs = 0)
            val error = assertFailsWith<CatalogException> { resolver.resolve(endpoint, "id", 1_000) }
            assertEquals(status, error.failure.status)
            assertEquals(1, calls)
            assertFalse(error.message.orEmpty().contains("secret"))
        }
    }

    @Test fun transientResponsesRetryWithStrictAttemptBound() = runTest {
        for (status in listOf(429, 500, 503)) {
            var calls = 0
            val resolver = AniDbSourceResolver(CatalogHttpTransport {
                calls++
                CatalogHttpResponse(status, "secret", mapOf("Retry-After" to "0"))
            }, retryDelayMs = 0)
            assertFailsWith<CatalogException> { resolver.resolve(endpoint, "id", 1_000) }
            assertEquals(3, calls)
        }
        var calls = 0
        val resolver = AniDbSourceResolver(CatalogHttpTransport {
            calls++
            if (calls < 3) CatalogHttpResponse(503, "") else CatalogHttpResponse(200, """{"link":"https://media.example.invalid/master.m3u8"}""")
        }, retryDelayMs = 0)
        assertEquals(PlaybackFormat.HLS, resolver.resolve(endpoint, "id", 1_000).format)
        assertEquals(3, calls)
    }

    @Test fun retryAfterIsRespectedWithoutShorteningLongOrDateBackoff() = runTest {
        for (status in listOf(429, 503)) {
            for (header in listOf("60", "Wed, 18 Nov 2026 12:00:00 GMT", "invalid", "-1")) {
                var calls = 0
                val resolver = AniDbSourceResolver(CatalogHttpTransport {
                    calls++
                    CatalogHttpResponse(status, "", mapOf("Retry-After" to header))
                }, retryDelayMs = 0)
                val error = assertFailsWith<CatalogException> { resolver.resolve(endpoint, "id", 1_000) }
                assertEquals(status, error.failure.status)
                assertEquals(1, calls, "Server backoff must never be shortened")
            }
        }
        var calls = 0
        val before = testScheduler.currentTime
        val resolver = AniDbSourceResolver(CatalogHttpTransport {
            calls++
            if (calls == 1) CatalogHttpResponse(429, "", mapOf("Retry-After" to "1"))
            else CatalogHttpResponse(200, """{"link":"https://media.example.invalid/master.m3u8"}""")
        }, retryDelayMs = 0)
        assertEquals(PlaybackFormat.HLS, resolver.resolve(endpoint, "id", 1_000).format)
        assertEquals(2, calls)
        assertEquals(1_000, testScheduler.currentTime - before)
    }

    @Test fun malformedSuccessfulResponsesAreNotRetried() = runTest {
        var calls = 0
        val resolver = AniDbSourceResolver(CatalogHttpTransport { calls++; CatalogHttpResponse(200, "invalid") }, retryDelayMs = 0)
        assertEquals(CatalogFailureKind.MALFORMED, assertFailsWith<CatalogException> { resolver.resolve(endpoint, "id", 1_000) }.failure.kind)
        assertEquals(1, calls)
    }

    @Test fun deadlineAndCallerCancellationRemainDistinct() = runTest {
        val resolver = AniDbSourceResolver(CatalogHttpTransport { awaitCancellation() }, timeoutMs = 10, retryDelayMs = 0)
        assertEquals(CatalogFailureKind.TIMEOUT, assertFailsWith<CatalogException> { resolver.resolve(endpoint, "id", 1_000) }.failure.kind)
        val started = CompletableDeferred<Unit>()
        val stopped = CompletableDeferred<Unit>()
        val service = AniDbSourceResolver(CatalogHttpTransport {
            started.complete(Unit)
            try { awaitCancellation() } finally { stopped.complete(Unit) }
        })
        val request = async { service.resolve(endpoint, "id", 1_000) }
        started.await(); request.cancelAndJoin()
        assertTrue(stopped.isCompleted)
    }

    @Test fun swiftCallbackCancellationCancelsNativeRequestAndSuppressesLateCompletion() = runTest {
        val callback = CompletableDeferred<CatalogHttpCompletion>()
        val cancelled = CompletableDeferred<Unit>()
        var delivered = false
        val client = AniDbSourceClient(object : CatalogCallbackTransport {
            override fun post(request: CatalogHttpRequest, completion: CatalogHttpCompletion): CatalogCancellation {
                callback.complete(completion)
                return object : CatalogCancellation { override fun cancel() { cancelled.complete(Unit) } }
            }
        })
        try {
            val request = client.resolve(endpoint, "id", 1_000, object : EpisodeSourceCompletion {
                override fun complete(source: PlaybackSource?, failure: CatalogFailure?) { delivered = true }
            })
            val pending = callback.await(); request.cancel(); cancelled.await()
            pending.complete(CatalogHttpResponse(200, """{"link":"https://media.example.invalid/master.m3u8"}"""), null)
            assertFalse(delivered)
        } finally { client.close() }
    }
}
