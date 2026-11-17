package com.anilili.catalog

import com.anilili.data.model.Media
import kotlinx.coroutines.CancellationException
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
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AniListCatalogTest {
    private fun catalog(body: String, status: Int = 200) = AniListCatalog(CatalogHttpTransport {
        CatalogHttpResponse(status, body)
    })

    @Test
    fun parsesSearchAndMapsOriginalDomain() = runTest {
        val page = catalog(CatalogFixtures.searchJson).search("fixture", page = 2)
        assertEquals(2, page.page)
        assertTrue(page.hasNextPage)
        val media = page.items.single()
        assertEquals(CatalogFixtures.expectedId, media.id)
        assertEquals(CatalogFixtures.expectedTitle, media.title.preferred)
        assertEquals("https://example.invalid/poster.jpg", media.coverImage.best)
        assertEquals(12, media.episodes)
        assertEquals(82, media.averageScore)
        assertEquals(listOf("Adventure"), media.genres)
    }

    @Test
    fun parsesDetailsAndComputedMapping() = runTest {
        val media = assertNotNull(catalog(CatalogFixtures.detailsJson).details(101))
        assertEquals(CatalogFixtures.expectedTitle, media.title.preferred)
        assertEquals("An original synthetic catalog fixture.", media.synopsis)
        assertEquals(4, media.airedEpisodes)
        assertEquals("https://example.invalid/backdrop.jpg", media.heroImage)
    }

    @Test
    fun optionalFieldsRetainExistingDefaults() = runTest {
        val media = assertNotNull(catalog("""{"data":{"Media":{"id":7}}}""").details(7))
        assertEquals("Untitled", media.title.preferred)
        assertNull(media.coverImage.best)
        assertNull(media.episodes)
        assertFalse(media.isAdult)
        assertTrue(media.genres.isEmpty())
    }

    @Test
    fun explicitNullsUseTheExistingAndroidCoercionPolicy() = runTest {
        val media = assertNotNull(catalog(CatalogFixtures.optionalNullJson).details(7))
        assertEquals("Untitled", media.title.preferred)
        assertNull(media.coverImage.best)
        assertTrue(media.genres.isEmpty())
        assertFalse(media.isAdult)
    }

    @Test
    fun nullAndEmptyResultsAreNotErrors() = runTest {
        assertTrue(catalog(CatalogFixtures.emptyJson).search("absent").items.isEmpty())
        assertNull(catalog("""{"data":{"Media":null}}""").details(99))
        assertTrue(catalog("""{"data":null}""").search("absent").items.isEmpty())
    }

    @Test
    fun lenientFieldsMatchTheExistingAndroidJsonPolicy() = runTest {
        val media = catalog("{data:{Media:{id:7,title:{english:Fixture}}}}").details(7)
        assertEquals("Fixture", media?.title?.preferred)
    }

    @Test
    fun malformedResponsesFailExplicitly() = runTest {
        for (body in listOf("not json", "[]", "{}", """{"data":{"Page":{"media":[{"id":"bad"}]}}}""")) {
            val error = assertFailsWith<CatalogException> { catalog(body).search("fixture") }
            assertEquals(CatalogFailureKind.MALFORMED, error.failure.kind)
        }
    }

    @Test
    fun httpErrorsRetainStatusWithoutLeakingBody() = runTest {
        val error = assertFailsWith<CatalogException> { catalog("secret response", 429).search("fixture") }
        assertEquals(CatalogFailureKind.HTTP, error.failure.kind)
        assertEquals(429, error.failure.status)
        assertFalse(error.message.orEmpty().contains("secret"))
    }

    @Test
    fun graphqlErrorsDoNotBecomeEmptyResults() = runTest {
        val error = assertFailsWith<CatalogException> {
            catalog("""{"data":null,"errors":[{"message":"private data"}]}""").search("fixture")
        }
        assertEquals(CatalogFailureKind.GRAPHQL, error.failure.kind)
        assertFalse(error.message.orEmpty().contains("private"))
    }

    @Test
    fun searchRequestPreservesPagingAndAdultPolicy() = runTest {
        val requests = mutableListOf<CatalogHttpRequest>()
        val service = AniListCatalog(CatalogHttpTransport { request ->
            requests += request
            CatalogHttpResponse(200, CatalogFixtures.emptyJson)
        })
        service.search("quotes \" and 日本語", 3, 17, hideAdult = false)
        service.search("fixture", 1, 20, hideAdult = true)
        val first = Json.parseToJsonElement(requests[0].body).jsonObject["variables"]!!.jsonObject
        assertEquals("quotes \" and 日本語", first["search"]!!.jsonPrimitive.content)
        assertEquals("3", first["page"]!!.jsonPrimitive.content)
        assertEquals("17", first["perPage"]!!.jsonPrimitive.content)
        assertFalse(first.containsKey("isAdult"))
        val second = Json.parseToJsonElement(requests[1].body).jsonObject["variables"]!!.jsonObject
        assertEquals("false", second["isAdult"]!!.jsonPrimitive.content)
        assertEquals("https://graphql.anilist.co", requests[0].url)
    }

    @Test
    fun callerCancellationCancelsTransport() = runTest {
        val started = CompletableDeferred<Unit>()
        val cancelled = CompletableDeferred<Unit>()
        val service = AniListCatalog(CatalogHttpTransport {
            started.complete(Unit)
            try { awaitCancellation() } finally { cancelled.complete(Unit) }
        })
        val request = async { service.search("fixture") }
        started.await()
        request.cancelAndJoin()
        assertTrue(cancelled.isCompleted)
    }

    @Test
    fun transportExceptionsPreserveExistingPlatformSemantics() = runTest {
        val failure = IllegalStateException("existing platform failure")
        val service = AniListCatalog(CatalogHttpTransport { throw failure })
        assertEquals(failure, assertFailsWith<IllegalStateException> { service.details(1) })
        val cancelled = AniListCatalog(CatalogHttpTransport { throw CancellationException("cancelled") })
        assertFailsWith<CancellationException> { cancelled.search("fixture") }
    }

    @Test
    fun mediaRoundTripKeepsOriginalSerializedFields() = runTest {
        val original = assertNotNull(catalog(CatalogFixtures.detailsJson).details(101))
        val encoded = Json.encodeToString(Media.serializer(), original)
        val restored = Json.decodeFromString(Media.serializer(), encoded)
        assertEquals(original, restored)
        assertFalse(Json.parseToJsonElement(encoded).jsonObject.containsKey("synopsis"))
    }
}
