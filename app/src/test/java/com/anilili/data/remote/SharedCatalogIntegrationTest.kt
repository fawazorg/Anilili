package com.anilili.data.remote

import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.Assert.*
import org.junit.Test

/** Exercises the shared catalog through Android's unchanged HTTP/throttle adapter. */
class SharedCatalogIntegrationTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test fun searchRetainsMetadataPaginationAndAndroidHeaders() = runBlocking {
        val server = MockWebServer()
        try {
            server.enqueue(MockResponse().setBody("""{"data":{"Page":{"pageInfo":{"hasNextPage":true},"media":[{"id":42,"title":{"english":"Fixture"},"episodes":12,"countryOfOrigin":"JP","nextAiringEpisode":{"episode":4}}]}}}"""))
            val client = AniListClient(OkHttpClient(), json, server.url("/graphql").toString())
            val page = client.search("fixture", page = 2, perPage = 5, hideAdult = true)
            assertEquals(2, page.page)
            assertTrue(page.hasNextPage)
            assertEquals("Fixture", page.items.single().title.preferred)
            assertEquals(3, page.items.single().airedEpisodes)
            assertEquals("JP", page.items.single().countryOfOrigin)
            val request = server.takeRequest()
            assertNotNull(request.getHeader("Referer"))
            assertNotNull(request.getHeader("User-Agent"))
            val vars = json.parseToJsonElement(request.body.readUtf8()).jsonObject.getValue("variables").jsonObject
            assertEquals("false", vars.getValue("isAdult").jsonPrimitive.content)
            assertEquals("2", vars.getValue("page").jsonPrimitive.content)
        } finally { server.shutdown() }
    }

    @Test fun detailsRetainFullModelAndNullNotFound() = runBlocking {
        val server = MockWebServer()
        try {
            server.enqueue(MockResponse().setBody("""{"data":{"Media":{"id":42,"description":"Synopsis","title":{"romaji":"Fixture"},"relations":{"edges":[{"relationType":"SEQUEL","node":{"id":43}}]},"streamingEpisodes":[{"title":"Episode 1","url":"https://example.invalid/1"}]}}}"""))
            server.enqueue(MockResponse().setBody("""{"data":{"Media":null}}"""))
            val client = AniListClient(OkHttpClient(), json, server.url("/graphql").toString())
            val media = client.animeInfo(42)!!
            assertEquals("Synopsis", media.description)
            assertEquals(43, media.relations.edges.single().node!!.id)
            assertEquals("Episode 1", media.streamingEpisodes.single().title)
            assertNull(client.animeInfo(99))
        } finally { server.shutdown() }
    }

    @Test fun sharedSearchRemainsCancellableThroughAndroidTransport() {
        val server = MockWebServer()
        try {
            server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
            val client = AniListClient(OkHttpClient(), json, server.url("/graphql").toString())
            assertThrows(TimeoutCancellationException::class.java) {
                runBlocking { withTimeout(200) { client.search("cancel") } }
            }
        } finally { server.shutdown() }
    }
}
