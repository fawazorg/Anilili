package com.anilili.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// ---- Media fields (superset of AniList MEDIA_LIST_FIELDS + info extras we render) ----
@Serializable
data class MediaTitle(
    val romaji: String? = null,
    val english: String? = null,
    val native: String? = null,
    val userPreferred: String? = null,
) {
    /** The app is English-first; AniList's viewer preference is only a fallback. */
    val preferred: String get() = english ?: userPreferred ?: romaji ?: native ?: "Untitled"
}

@Serializable
data class CoverImage(
    val large: String? = null,
    val extraLarge: String? = null,
    val color: String? = null,
) {
    val best: String? get() = extraLarge ?: large
}

@Serializable
data class FuzzyDate(val year: Int? = null, val month: Int? = null, val day: Int? = null)

@Serializable
data class NextAiringEpisode(
    val episode: Int? = null,
    val airingAt: Long? = null,
    val timeUntilAiring: Long? = null,
)

@Serializable
data class StudioNode(
    val id: Int = 0,
    val name: String? = null,
    val isAnimationStudio: Boolean = false,
)

@Serializable
data class StudioConnection(val nodes: List<StudioNode> = emptyList())

@Serializable
data class Trailer(val id: String? = null, val site: String? = null, val thumbnail: String? = null) {
    /**
     * The page the trailer plays on, handed to whatever app claims it (usually YouTube).
     *
     * AniList only ever names `youtube` or `dailymotion`; anything else has no URL we could build,
     * and a card that opens nothing is worse than no card.
     */
    val watchUrl: String?
        get() {
            val videoId = id?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            return when (site?.lowercase()) {
                "youtube" -> "https://www.youtube.com/watch?v=$videoId"
                "dailymotion" -> "https://www.dailymotion.com/video/$videoId"
                else -> null
            }
        }
}

/**
 * One row of AniList's per-episode streaming links, which carry a thumbnail.
 *
 * These are the licensor's own stills (mostly Crunchyroll) and they ride the detail query the app
 * already makes, so they cost nothing extra. What they do not carry is an episode *number* — the
 * number only ever appears inside [title], as "Episode 12 - Something". That is why this is the
 * last source consulted and can never outrank TMDB: a title AniList wrote differently is an
 * episode this cannot place at all.
 */
@Serializable
data class StreamingEpisode(
    val title: String? = null,
    val thumbnail: String? = null,
    val url: String? = null,
    val site: String? = null,
)

@Serializable
data class MediaRelationEdge(
    val relationType: String? = null,
    val node: Media? = null,
)

@Serializable
data class MediaRelationConnection(val edges: List<MediaRelationEdge> = emptyList())

@Serializable
data class Media(
    val id: Int,
    val idMal: Int? = null,
    val title: MediaTitle = MediaTitle(),
    val description: String? = null,
    val coverImage: CoverImage = CoverImage(),
    val bannerImage: String? = null,
    val format: String? = null,
    val season: String? = null,
    val seasonYear: Int? = null,
    val episodes: Int? = null,
    val duration: Int? = null,
    val status: String? = null,
    val averageScore: Int? = null,
    val meanScore: Int? = null,
    val popularity: Int? = null,
    val favourites: Int? = null,
    val isAdult: Boolean = false,
    /**
     * ISO 3166-1 alpha-2 country of the studio that made it: `JP` for anime, `CN` for donghua,
     * `KR` for aeni. Nullable because it is absent from every cached [Media] written before the
     * field was requested, and those entries stay readable for the life of the 24h media cache.
     */
    val countryOfOrigin: String? = null,
    val genres: List<String> = emptyList(),
    val tags: List<MediaTag> = emptyList(),
    val studios: StudioConnection = StudioConnection(),
    val nextAiringEpisode: NextAiringEpisode? = null,
    val startDate: FuzzyDate? = null,
    val endDate: FuzzyDate? = null,
    val trailer: Trailer? = null,
    val relations: MediaRelationConnection = MediaRelationConnection(),
    val streamingEpisodes: List<StreamingEpisode> = emptyList(),
) {
    /**
     * Backdrop for the wide hero banners, best landscape source first.
     *
     * AniList has no dedicated key art field, so this is a preference order over what it does
     * carry. `bannerImage` is the only purpose-built one (1900x400). The trailer frame is 16:9 and
     * therefore still crops sensibly across a hero; it is lower resolution than the cover, but a
     * soft landscape still behind a heavy scrim reads far better than a portrait poster sliced
     * down to a letterbox strip. The cover is the last resort.
     */
    /** Swift-friendly name; computed only, so persisted JSON stays unchanged. */
    val synopsis: String? get() = description

    val heroImage: String? get() =
        bannerImage ?: trailer?.thumbnail ?: coverImage.extraLarge ?: coverImage.best

    /**
     * How many episodes have actually been released, or null when that cannot be told apart from
     * "unknown".
     *
     * Distinct from [episodes], which is the *planned* run and is populated for a series long
     * before it has aired — treating the two as interchangeable is what let Continue Watching
     * advance onto an episode that does not exist yet. Only a releasing series can answer: a
     * finished one has no `nextAiringEpisode`, and there [episodes] is already the right bound.
     */
    val airedEpisodes: Int? get() = nextAiringEpisode?.episode?.minus(1)?.takeIf { it > 0 }
}

@Serializable
data class MediaTag(
    val name: String,
    val description: String? = null,
    val category: String? = null,
    val isAdult: Boolean = false,
    val rank: Int? = null,
    val isMediaSpoiler: Boolean = false,
    val isGeneralSpoiler: Boolean = false,
)

// ---- Response envelopes ----
@Serializable
data class PageInfo(
    val total: Int = 0,
    val currentPage: Int = 1,
    val lastPage: Int = 1,
    val hasNextPage: Boolean = false,
    val perPage: Int = 20,
)

@Serializable
data class Page(
    val pageInfo: PageInfo = PageInfo(),
    val media: List<Media> = emptyList(),
)

@Serializable
data class PageData(@SerialName("Page") val page: Page? = null)

@Serializable
data class MediaData(@SerialName("Media") val media: Media? = null)

@Serializable
data class GqlPageResponse(val data: PageData? = null)

@Serializable
data class GqlMediaResponse(val data: MediaData? = null)

/** A page of results plus whether more exist — used to drive infinite scroll. */
@Serializable
data class MediaPage(
    val items: List<Media>,
    val hasNextPage: Boolean,
    val page: Int,
    /**
     * How many titles match in total, or 0 when the source cannot say.
     *
     * Defaulted rather than required because most callers here page through a list and never ask;
     * only Browse shows it, where "412 results" is the fastest way to tell a filter that narrowed
     * things from one that emptied them.
     */
    val total: Int = 0,
)
