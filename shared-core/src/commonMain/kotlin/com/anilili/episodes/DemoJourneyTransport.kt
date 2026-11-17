package com.anilili.episodes

import com.anilili.catalog.CatalogCallbackTransport
import com.anilili.catalog.CatalogCancellation
import com.anilili.catalog.CatalogHttpCompletion
import com.anilili.catalog.CatalogHttpRequest
import com.anilili.catalog.CatalogHttpResponse
import com.anilili.data.model.GqlMediaResponse
import com.anilili.data.model.GqlPageResponse
import com.anilili.data.model.Media
import com.anilili.data.model.MediaData
import com.anilili.data.model.MediaTitle
import com.anilili.data.model.Page
import com.anilili.data.model.PageData
import com.anilili.data.model.PageInfo
import kotlinx.serialization.builtins.nullable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * Original offline demo provider, deliberately separate from live AniList identities.
 * The normal shared AniList parser and episode repository consume these responses.
 * Swift only maps an allowlisted fixture URL to a bundled original media asset.
 */
class DemoJourneyTransport : CatalogCallbackTransport {
    private val json = Json { ignoreUnknownKeys = true }
    private val catalog = listOf(
        Media(id = 101, title = MediaTitle(english = "Anilili Demo Adventures"),
            description = "Original synthetic media for the catalog-to-playback journey.", format = "TV",
            episodes = 4, genres = listOf("Demo")),
        Media(id = 102, title = MediaTitle(english = "Anilili Empty Season"),
            description = "An original fixture with no available episodes.", format = "TV", episodes = 0),
    )
    private val rows = listOf(
        Episode("demo-mp4", 101, 1, "MP4 test pattern"),
        Episode("demo-hls", 101, 2, "HLS test pattern"),
        Episode("demo-missing", 101, 3, "Unavailable source"),
        Episode("demo-invalid", 101, 4, "Invalid media error"),
    )

    override fun post(request: CatalogHttpRequest, completion: CatalogHttpCompletion): CatalogCancellation {
        completion.complete(response(request), null)
        return object : CatalogCancellation { override fun cancel() {} }
    }

    fun response(request: CatalogHttpRequest): CatalogHttpResponse = try {
        val body = json.parseToJsonElement(request.body) as? JsonObject
        when (request.url) {
            "demo://catalog" -> catalogResponse(body ?: error("Missing body"))
            "demo://episodes" -> episodeResponse(body ?: error("Missing body"))
            else -> CatalogHttpResponse(404, "{}")
        }
    } catch (_: Exception) { CatalogHttpResponse(400, "{}") }

    private fun catalogResponse(body: JsonObject): CatalogHttpResponse {
        val variables = body["variables"] as? JsonObject ?: error("Missing variables")
        val id = variables["id"]?.jsonPrimitive?.intOrNull
        if (id != null) {
            return CatalogHttpResponse(200, json.encodeToString(GqlMediaResponse.serializer(),
                GqlMediaResponse(MediaData(catalog.firstOrNull { it.id == id }))))
        }
        val search = variables["search"]?.jsonPrimitive?.contentOrNull.orEmpty().trim()
        val page = (variables["page"]?.jsonPrimitive?.intOrNull ?: 1).coerceAtLeast(1)
        val perPage = (variables["perPage"]?.jsonPrimitive?.intOrNull ?: 20).coerceIn(1, 50)
        val filtered = catalog.filter { it.title.preferred.contains(search, ignoreCase = true) }
        val offset = ((page.toLong() - 1) * perPage).coerceAtMost(filtered.size.toLong()).toInt()
        val items = filtered.drop(offset).take(perPage)
        val pageInfo = PageInfo(total = filtered.size, currentPage = page, perPage = perPage,
            hasNextPage = offset + items.size < filtered.size)
        return CatalogHttpResponse(200, json.encodeToString(GqlPageResponse.serializer(),
            GqlPageResponse(PageData(Page(pageInfo, items)))))
    }

    private fun episodeResponse(body: JsonObject): CatalogHttpResponse {
        val animeId = body["animeId"]?.jsonPrimitive?.intOrNull ?: error("Missing anime")
        if (catalog.none { it.id == animeId }) return CatalogHttpResponse(404, "{}")
        return when (body["operation"]?.jsonPrimitive?.contentOrNull) {
            "episodes" -> CatalogHttpResponse(200, buildJsonObject {
                put("episodes", json.encodeToJsonElement(ListSerializer(Episode.serializer()), rows.filter { it.animeId == animeId }))
            }.toString())
            "resolve" -> {
                val id = body["episodeId"]?.jsonPrimitive?.contentOrNull
                if (rows.none { it.animeId == animeId && it.id == id }) return CatalogHttpResponse(404, "{}")
                val source = when (id) {
                    "demo-mp4" -> PlaybackSource(id, "fixture://progressive.mp4", PlaybackFormat.MP4)
                    "demo-hls" -> PlaybackSource(id, "fixture://hls/master.m3u8", PlaybackFormat.HLS)
                    "demo-invalid" -> PlaybackSource(id, "fixture://invalid.mp4", PlaybackFormat.MP4)
                    else -> null
                }
                CatalogHttpResponse(200, buildJsonObject {
                    put("source", json.encodeToJsonElement(PlaybackSource.serializer().nullable, source))
                }.toString())
            }
            else -> CatalogHttpResponse(400, "{}")
        }
    }
}
