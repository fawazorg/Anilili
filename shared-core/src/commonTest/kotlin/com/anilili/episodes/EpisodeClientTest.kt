package com.anilili.episodes

import com.anilili.catalog.CatalogCallbackTransport
import com.anilili.catalog.CatalogCancellation
import com.anilili.catalog.CatalogFailure
import com.anilili.catalog.CatalogHttpCompletion
import com.anilili.catalog.CatalogHttpRequest
import com.anilili.catalog.CatalogHttpResponse
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class EpisodeClientTest {
    @Test fun callbackBridgeListsAndResolvesSharedDemoProvider() = runTest {
        val client = EpisodeClient(DemoJourneyTransport(), "demo://episodes")
        val rows = CompletableDeferred<List<Episode>>()
        val selected = CompletableDeferred<PlaybackSource>()
        try {
            client.episodes(101, object : EpisodeListCompletion {
                override fun complete(episodes: List<Episode>?, failure: CatalogFailure?) {
                    assertNull(failure)
                    rows.complete(requireNotNull(episodes))
                }
            })
            val first = rows.await().first()
            client.resolve(first.animeId, first.id, object : EpisodeSourceCompletion {
                override fun complete(source: PlaybackSource?, failure: CatalogFailure?) {
                    assertNull(failure)
                    selected.complete(requireNotNull(source))
                }
            })
            assertEquals("fixture://progressive.mp4", selected.await().url)
        } finally { client.close() }
    }

    @Test fun cancellationCancelsNativeResolutionAndIgnoresLateCompletion() = runTest {
        val started = CompletableDeferred<CatalogHttpCompletion>()
        val cancelled = CompletableDeferred<Unit>()
        val delivered = CompletableDeferred<Unit>()
        val client = EpisodeClient(object : CatalogCallbackTransport {
            override fun post(request: CatalogHttpRequest, completion: CatalogHttpCompletion): CatalogCancellation {
                started.complete(completion)
                return object : CatalogCancellation { override fun cancel() { cancelled.complete(Unit) } }
            }
        }, "https://example.invalid/provider")
        try {
            val request = client.resolve(101, "a", object : EpisodeSourceCompletion {
                override fun complete(source: PlaybackSource?, failure: CatalogFailure?) { delivered.complete(Unit) }
            })
            val callback = started.await()
            request.cancel()
            cancelled.await()
            callback.complete(CatalogHttpResponse(200, """{"source":{"episodeId":"a","url":"https://example.invalid/a.mp4","format":"MP4"}}"""), null)
            assertTrue(cancelled.isCompleted)
            assertFalse(delivered.isCompleted)
        } finally { client.close() }
    }
}
