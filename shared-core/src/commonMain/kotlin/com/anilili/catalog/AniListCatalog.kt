package com.anilili.catalog

import com.anilili.data.model.GqlMediaResponse
import com.anilili.data.model.GqlPageResponse
import com.anilili.data.model.Media
import com.anilili.data.model.MediaPage
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Platform adapters own HTTP execution, credentials, retry policy, and cancellation. */
data class CatalogHttpRequest(val url: String, val body: String, val method: String, val headers: Map<String, String>) {
    constructor(url: String, body: String) : this(url, body, "POST", emptyMap())
}
data class CatalogHttpResponse(val status: Int, val body: String, val headers: Map<String, String>, val finalUrl: String?) {
    constructor(status: Int, body: String) : this(status, body, emptyMap(), null)
    constructor(status: Int, body: String, headers: Map<String, String>) : this(status, body, headers, null)
}
fun interface CatalogHttpTransport {
    suspend fun post(request: CatalogHttpRequest): CatalogHttpResponse
}

enum class CatalogFailureKind { HTTP, GRAPHQL, MALFORMED, TRANSPORT, TIMEOUT, EXPIRED, UNSUPPORTED }
data class CatalogFailure(val kind: CatalogFailureKind, val status: Int, val message: String)
class CatalogException(val failure: CatalogFailure) : Exception(failure.message)

@OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
class AniListCatalog(
    private val transport: CatalogHttpTransport,
    private val endpoint: String = "https://graphql.anilist.co",
    private val json: Json = Json { ignoreUnknownKeys = true; isLenient = true; coerceInputValues = true; explicitNulls = false },
) {
    suspend fun search(query: String, page: Int = 1, perPage: Int = 20, hideAdult: Boolean = false): MediaPage {
        val gql = """
            query (${'$'}search: String, ${'$'}page: Int, ${'$'}perPage: Int, ${'$'}isAdult: Boolean) {
              Page(page: ${'$'}page, perPage: ${'$'}perPage) {
                pageInfo { hasNextPage currentPage }
                media(search: ${'$'}search, type: ANIME, sort: SEARCH_MATCH, isAdult: ${'$'}isAdult) { ${AniListCatalogQueries.listFields} }
              }
            }
        """.trimIndent()
        val vars = buildJsonObject {
            put("search", query)
            put("page", page)
            put("perPage", perPage)
            if (hideAdult) put("isAdult", false)
        }
        val body = post(gql, vars)
        val parsed = decode { json.decodeFromJsonElement(GqlPageResponse.serializer(), body) }.data?.page
        return MediaPage(parsed?.media.orEmpty(), parsed?.pageInfo?.hasNextPage ?: false, page, parsed?.pageInfo?.total ?: 0)
    }

    suspend fun details(id: Int): Media? {
        val gql = """
            query (${'$'}id: Int) {
              Media(id: ${'$'}id, type: ANIME) { ${AniListCatalogQueries.fullFields} }
            }
        """.trimIndent()
        val body = post(gql, buildJsonObject { put("id", id) })
        return decode { json.decodeFromJsonElement(GqlMediaResponse.serializer(), body) }.data?.media
    }

    private suspend fun post(query: String, variables: JsonObject): JsonObject {
        currentCoroutineContext().ensureActive()
        val body = buildJsonObject { put("query", query); put("variables", variables) }.toString()
        // Preserve platform exceptions, including Android's existing auth/rate-limit guidance.
        val response = transport.post(CatalogHttpRequest(endpoint, body))
        currentCoroutineContext().ensureActive()
        if (response.status !in 200..299) {
            throw CatalogException(CatalogFailure(CatalogFailureKind.HTTP, response.status, "AniList HTTP ${response.status}"))
        }
        val root = decode { json.parseToJsonElement(response.body) } as? JsonObject
            ?: throw malformed()
        val errors = root["errors"]
        if (errors != null && errors !is kotlinx.serialization.json.JsonNull) {
            if (errors !is JsonArray) throw malformed()
            if (errors.isNotEmpty()) {
                // Do not echo provider bodies, tokens, or private messages into UI/logs.
                throw CatalogException(CatalogFailure(CatalogFailureKind.GRAPHQL, 0, "AniList returned GraphQL errors"))
            }
        }
        if (!root.containsKey("data")) throw malformed()
        return root
    }

    private inline fun <T> decode(block: () -> T): T = try { block() }
    catch (_: SerializationException) { throw malformed() }
    catch (_: IllegalArgumentException) { throw malformed() }

    private fun malformed() = CatalogException(CatalogFailure(CatalogFailureKind.MALFORMED, 0, "Invalid AniList response"))
}
