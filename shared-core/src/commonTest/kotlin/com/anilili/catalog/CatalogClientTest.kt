package com.anilili.catalog

import com.anilili.data.model.MediaPage
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CatalogClientTest {
    @Test
    fun swiftBridgeUsesTheSameParserAndModels() = runTest {
        val received = CompletableDeferred<MediaPage>()
        val client = CatalogClient(object : CatalogCallbackTransport {
            override fun post(request: CatalogHttpRequest, completion: CatalogHttpCompletion): CatalogCancellation {
                completion.complete(CatalogHttpResponse(200, CatalogFixtures.searchJson), null)
                return object : CatalogCancellation { override fun cancel() {} }
            }
        }, "https://example.invalid/catalog")
        try {
            client.search("fixture", 2, 20, false, object : CatalogPageCompletion {
                override fun complete(page: MediaPage?, failure: CatalogFailure?) {
                    assertNull(failure)
                    received.complete(requireNotNull(page))
                }
            })
            val page = received.await()
            assertEquals(CatalogFixtures.expectedTitle, page.items.single().title.preferred)
            assertEquals(CatalogFixtures.expectedId, page.items.single().id)
            assertEquals(2, page.page)
        } finally { client.close() }
    }

    @Test
    fun cancellingTheBridgeCancelsNativeRequestAndSuppressesLateResult() = runTest {
        val started = CompletableDeferred<CatalogHttpCompletion>()
        val cancelled = CompletableDeferred<Unit>()
        val delivered = CompletableDeferred<Unit>()
        val client = CatalogClient(object : CatalogCallbackTransport {
            override fun post(request: CatalogHttpRequest, completion: CatalogHttpCompletion): CatalogCancellation {
                started.complete(completion)
                return object : CatalogCancellation { override fun cancel() { cancelled.complete(Unit) } }
            }
        }, "https://example.invalid/catalog")
        try {
            val request = client.search("fixture", 1, 20, false, object : CatalogPageCompletion {
                override fun complete(page: MediaPage?, failure: CatalogFailure?) { delivered.complete(Unit) }
            })
            val nativeCallback = started.await()
            request.cancel()
            cancelled.await()
            nativeCallback.complete(CatalogHttpResponse(200, CatalogFixtures.searchJson), null)
            assertTrue(cancelled.isCompleted)
            assertFalse(delivered.isCompleted)
        } finally { client.close() }
    }
}
