package com.anilili.data.remote

import com.anilili.catalog.CatalogException
import com.anilili.catalog.CatalogFailureKind
import com.anilili.episodes.PlaybackFormat
import com.anilili.provider.AniDbSourceParser
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class AniDbSharedSourceCompatibilityTest {
    @Test fun existingAndroidParserDelegatesToSharedHeaderFreeHlsMapping() {
        val body = """{"link":"https://cdn.example.invalid/master.m3u8"}"""
        assertEquals(AniDbSourceParser.parse(body, "known-server", "https://play.anidb.app/api/", 0).url,
            AniDbAppParser.link(Json.parseToJsonElement(body)))
    }

    @Test fun sharedMappingRetainsSourceMetadataWithoutPlatformMediaObjects() {
        val body = """{"link":"https://cdn.example.invalid/video.mp4","headers":{"User-Agent":"Fixture"},"audioTracks":[{"id":"en","label":"English","language":"en"}]}"""
        val source = AniDbSourceParser.parse(body, "episode/jpn", "https://play.anidb.app/api/", 0)
        assertEquals(PlaybackFormat.MP4, source.format)
        assertEquals("Fixture", source.headers["User-Agent"])
        assertEquals("en", source.audioTracks.single().language)
    }

    @Test fun malformedAndCredentialBearingUrlsAreNotForwardedToMedia3() {
        for (link in listOf("javascript:bad", "https://secret:token@cdn.example.invalid/master.m3u8")) {
            assertNull(AniDbAppParser.link(Json.parseToJsonElement("""{"link":"$link"}""")))
        }
        val error = assertThrows(CatalogException::class.java) {
            AniDbSourceParser.parse("""{"link":"https://cdn.example.invalid/master.m3u8","expiresAtMs":1}""", "id", "https://play.anidb.app/api/", 2)
        }
        assertEquals(CatalogFailureKind.EXPIRED, error.failure.kind)
    }
}
