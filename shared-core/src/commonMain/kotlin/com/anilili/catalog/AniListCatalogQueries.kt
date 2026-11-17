package com.anilili.catalog

/** The existing Android query fields, shared without changing requested metadata. */
object AniListCatalogQueries {
    val listFields = """
        id
        idMal
        title { romaji english native userPreferred }
        coverImage { large extraLarge color }
        bannerImage
        trailer { thumbnail }
        format
        season
        seasonYear
        episodes
        duration
        status
        averageScore
        popularity
        isAdult
        countryOfOrigin
        genres
        studios(isMain: true) { nodes { id name isAnimationStudio } }
        nextAiringEpisode { episode airingAt timeUntilAiring }
        startDate { year month day }
    """.trimIndent()


    val fullFields = """
        id
        idMal
        title { romaji english native userPreferred }
        description(asHtml: false)
        coverImage { large extraLarge color }
        bannerImage
        format
        season
        seasonYear
        episodes
        duration
        status
        averageScore
        meanScore
        popularity
        favourites
        isAdult
        countryOfOrigin
        genres
        tags { name rank isMediaSpoiler isGeneralSpoiler }
        studios { nodes { id name isAnimationStudio } }
        trailer { id site thumbnail }
        nextAiringEpisode { episode airingAt timeUntilAiring }
        startDate { year month day }
        endDate { year month day }
        streamingEpisodes { title thumbnail url site }
        relations {
          edges {
            relationType
            node { $listFields }
          }
        }
    """.trimIndent()

}
