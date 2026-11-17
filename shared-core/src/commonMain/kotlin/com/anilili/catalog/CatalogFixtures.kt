package com.anilili.catalog

/** Synthetic responses used on JVM, Native, and Swift: no live-provider availability in CI. */
object CatalogFixtures {
    val expectedId: Int = 101
    val expectedTitle: String = "Fixture English"
    val searchJson: String = """{"data":{"Page":{"pageInfo":{"hasNextPage":true,"currentPage":2},"media":[{"id":101,"title":{"english":"Fixture English","romaji":"Fixture Romaji"},"coverImage":{"large":"https://example.invalid/poster.jpg"},"format":"TV","episodes":12,"averageScore":82,"genres":["Adventure"],"unknownFutureField":true}]}}}"""
    val detailsJson: String = """{"data":{"Media":{"id":101,"title":{"english":"Fixture English"},"description":"An original synthetic catalog fixture.","coverImage":{"large":"https://example.invalid/poster.jpg"},"format":"TV","episodes":12,"averageScore":82,"genres":["Adventure"],"nextAiringEpisode":{"episode":5},"trailer":{"site":"youtube","id":"fixture","thumbnail":"https://example.invalid/backdrop.jpg"}}}}"""
    val optionalNullJson: String = """{"data":{"Media":{"id":7,"title":null,"coverImage":null,"genres":null,"isAdult":null}}}"""
    val emptyJson: String = """{"data":{"Page":{"media":[]}}}"""
}
