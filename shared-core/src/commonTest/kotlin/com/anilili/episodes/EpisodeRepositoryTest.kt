package com.anilili.episodes

import com.anilili.catalog.AniListCatalog
import com.anilili.catalog.CatalogException
import com.anilili.catalog.CatalogFailureKind
import com.anilili.catalog.CatalogHttpRequest
import com.anilili.catalog.CatalogHttpResponse
import com.anilili.catalog.CatalogHttpTransport
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class EpisodeRepositoryTest {
    private fun repository(body: String, status: Int = 200) = EpisodeRepository(CatalogHttpTransport {
        CatalogHttpResponse(status, body)
    }, "https://example.invalid/episodes")

    @Test fun demoConnectsTheExistingCatalogToBothMediaFormats() = runTest {
        val demo = DemoJourneyTransport()
        val transport = CatalogHttpTransport { demo.response(it) }
        val catalog = AniListCatalog(transport, "demo://catalog")
        val provider = EpisodeRepository(transport, "demo://episodes")
        val page = catalog.search("")
        assertEquals(listOf(101, 102), page.items.map { it.id })
        val details = catalog.details(page.items.first().id)!!
        assertEquals("Anilili Demo Adventures", details.title.preferred)
        val rows = provider.episodes(details.id)
        assertEquals(listOf(1, 2, 3, 4), rows.map { it.number })
        assertEquals("fixture://progressive.mp4", provider.resolve(details.id, rows[0].id).url)
        assertEquals(PlaybackFormat.HLS, provider.resolve(details.id, rows[1].id).format)
        assertEquals("fixture://hls/master.m3u8", provider.resolve(details.id, rows[1].id).url)
        assertTrue(provider.episodes(102).isEmpty())
    }

    @Test fun demoSearchAndPagingAreSharedNotSwiftLogic() = runTest {
        val demo = DemoJourneyTransport()
        val catalog = AniListCatalog(CatalogHttpTransport { demo.response(it) }, "demo://catalog")
        assertEquals(102, catalog.search("empty").items.single().id)
        assertTrue(catalog.search("missing title").items.isEmpty())
        assertTrue(catalog.search("", perPage = 1).hasNextPage)
        assertEquals(102, catalog.search("", page = 2, perPage = 1).items.single().id)
        assertFalse(catalog.search("", page = 2, perPage = 1).hasNextPage)
        assertTrue(catalog.search("", page = Int.MAX_VALUE).items.isEmpty())
    }

    @Test fun demoMissingAndInvalidMediaRemainExplicitScenarios() = runTest {
        val demo = DemoJourneyTransport()
        val provider = EpisodeRepository(CatalogHttpTransport { demo.response(it) }, "demo://episodes")
        val missing = assertFailsWith<CatalogException> { provider.resolve(101, "demo-missing") }
        assertEquals(404, missing.failure.status)
        assertEquals("fixture://invalid.mp4", provider.resolve(101, "demo-invalid").url)
        assertEquals(404, assertFailsWith<CatalogException> { provider.resolve(102, "demo-mp4") }.failure.status)
    }

    @Test fun parsesOptionalSourceHeadersAndSortsEpisodes() = runTest {
        val rows = repository("""{"episodes":[{"id":"b","animeId":7,"number":2,"title":"Second"},{"id":"a","animeId":7,"number":1,"title":"First"}]}""").episodes(7)
        assertEquals(listOf("a", "b"), rows.map { it.id })
        val source = repository("""{"source":{"episodeId":"a","url":"https://example.invalid/video.mp4","format":"MP4","headers":{"User-Agent":"Anilili"},"future":true}}""").resolve(7, "a")
        assertEquals("Anilili", source.headers["User-Agent"])
        val minimal = repository("""{"source":{"episodeId":"a","url":"https://example.invalid/video.m3u8","format":"HLS"}}""").resolve(7, "a")
        assertTrue(minimal.headers.isEmpty())
    }

    @Test fun rejectsMalformedListsAndIdentityMismatches() = runTest {
        for (body in listOf("[]", "{}", "not json", """{"episodes":[{"id":"a","animeId":8,"number":1,"title":"Wrong anime"}]}""", """{"episodes":[{"id":"a","animeId":7,"number":0,"title":"Invalid"}]}""", """{"episodes":[{"id":"a","animeId":7,"number":1,"title":"First"},{"id":"a","animeId":7,"number":2,"title":"Duplicate"}]}""")) {
            assertEquals(CatalogFailureKind.MALFORMED, assertFailsWith<CatalogException> { repository(body).episodes(7) }.failure.kind)
        }
    }

    @Test fun rejectsUnsupportedSourceFormatsSchemesAndMismatchedIds() = runTest {
        for ((id, url, format) in listOf(Triple("other", "https://example.invalid/a.mp4", "MP4"), Triple("a", "javascript:bad", "MP4"), Triple("a", "https://example.invalid/a.mpd", "DASH"), Triple("a", "fixture://../../secret.mp4", "MP4"), Triple("a", "https://private@example.invalid/a.mp4", "MP4"))) {
            val body = """{"source":{"episodeId":"$id","url":"$url","format":"$format"}}"""
            assertEquals(CatalogFailureKind.MALFORMED, assertFailsWith<CatalogException> { repository(body).resolve(7, "a") }.failure.kind)
        }
    }

    @Test fun missingSourceAndHttpFailuresNeverBecomeSuccessfulPlayback() = runTest {
        assertEquals(404, assertFailsWith<CatalogException> { repository("""{"source":null}""").resolve(7, "a") }.failure.status)
        val failure = assertFailsWith<CatalogException> { repository("private body", 503).episodes(7) }
        assertEquals(CatalogFailureKind.HTTP, failure.failure.kind)
        assertEquals(503, failure.failure.status)
        assertFalse(failure.message.orEmpty().contains("private"))
    }

    @Test fun requestIncludesBothAnimeAndEpisodeIdentity() = runTest {
        var captured: CatalogHttpRequest? = null
        val provider = EpisodeRepository(CatalogHttpTransport {
            captured = it
            CatalogHttpResponse(200, """{"source":null}""")
        }, "https://example.invalid/provider")
        assertFailsWith<CatalogException> { provider.resolve(7, "episode-2") }
        val request = Json.parseToJsonElement(captured!!.body).jsonObject
        assertEquals("resolve", request["operation"]!!.jsonPrimitive.content)
        assertEquals("7", request["animeId"]!!.jsonPrimitive.content)
        assertEquals("episode-2", request["episodeId"]!!.jsonPrimitive.content)
    }

    @Test fun cancellationReachesTheInjectedTransport() = runTest {
        val started = CompletableDeferred<Unit>()
        val cancelled = CompletableDeferred<Unit>()
        val provider = EpisodeRepository(CatalogHttpTransport {
            started.complete(Unit)
            try { awaitCancellation() } finally { cancelled.complete(Unit) }
        }, "https://example.invalid/provider")
        val request = async { provider.resolve(7, "a") }
        started.await()
        request.cancelAndJoin()
        assertTrue(cancelled.isCompleted)
    }
}
