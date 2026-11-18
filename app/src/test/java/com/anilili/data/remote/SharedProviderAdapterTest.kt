package com.anilili.data.remote

import com.anilili.data.model.SkipTimes
import com.anilili.provider.AniChanSharedParser
import com.anilili.provider.AniPmSharedParser
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.*
import org.junit.Test

class SharedProviderAdapterTest {
    @Test fun aniPmAdapterPreservesExistingSkipMetadataAndSharedMediaMapping() {
        val session = Json.parseToJsonElement("""{"source":"https://media.example/master.m3u8","kind":"hls","subtitles":[{"url":"https://media.example/eng.vtt","label":"English","srclang":"eng"}]}""") as JsonObject
        val skip = SkipTimes(2.0, 90.0, null, null, recapStart = 0.0, recapEnd = 1.5, introSkipId = "existing-id")
        val android = AniPmParser.sources(session, skip)
        val shared = AniPmSharedParser.sources(session, null)
        assertSame(skip, android.skip)
        assertEquals(shared.streams.single().url, android.streams.single().url)
        assertEquals(shared.subtitles.single().language, android.subtitles.single().language)
        assertNull(android.streams.single().referer)
        assertTrue(android.streams.single().headers.isEmpty())
    }

    @Test fun aniChanAdapterPreservesSharedRankingAndFirstServerTrackAssociation() {
        val servers = Json.parseToJsonElement("""[{"name":"backup","rank":2,"stream":"https://media.example/backup.m3u8","subtitles":[{"url":"/wrong.vtt","lang":"French"}]},{"name":"anichan","rank":1,"label":"★ Main","stream":"/master.m3u8","subtitles":[{"url":"/English (CR).vtt","lang":"English"}]}]""") as JsonArray
        val shared = AniChanSharedParser.sources(servers)
        val android = AniChanParser.sources(servers)
        assertEquals(shared.streams.map { it.url }, android.streams.map { it.url })
        assertEquals(shared.streams.map { it.quality }, android.streams.map { it.quality })
        assertEquals(listOf(true, false), android.streams.map { it.isActive })
        assertEquals("https://anichan.to/English%20(CR).vtt", android.subtitles.single().url)
        assertNull(android.skip)
    }
}
