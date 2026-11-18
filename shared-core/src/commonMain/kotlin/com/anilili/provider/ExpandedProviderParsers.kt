package com.anilili.provider

import com.anilili.episodes.PlaybackTrack
import kotlinx.serialization.json.*

/** Parsed provider payloads precede platform media adapters; no Android media types escape. */
data class ProviderAvailability(val sub: Set<Int>, val dub: Set<Int>)
data class ProviderStream(val url: String, val type: String, val quality: String?, val active: Boolean)
data class ProviderSkip(val introStart: Double?, val introEnd: Double?, val outroStart: Double?, val outroEnd: Double?)
data class ParsedProviderSources(val streams: List<ProviderStream>, val subtitles: List<PlaybackTrack>, val skip: ProviderSkip?)

object AniPmSharedParser {
    fun availability(root: JsonObject): ProviderAvailability {
        val rows = root["episodes"] as? JsonObject ?: return ProviderAvailability(emptySet(), emptySet())
        val sub = mutableSetOf<Int>(); val dub = mutableSetOf<Int>()
        for ((key, value) in rows) {
            val number = key.toIntOrNull()?.takeIf { it > 0 } ?: continue
            val row = value as? JsonObject ?: continue
            if (row.flag("sub")) sub += number
            if (row.flag("dub")) dub += number
        }
        return ProviderAvailability(sub, dub)
    }

    fun sources(session: JsonObject, skip: ProviderSkip?, allowLocalFixtures: Boolean = false): ParsedProviderSources {
        val source = session.text("source")?.takeIf { it.startsWith("https://") || allowLocalFixtures && localFixtureUrl(it) }
            ?: error("Settlar session carried no stream")
        val subtitles = (session["subtitles"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
            .filter { it.text("url")?.startsWith("https://") == true || allowLocalFixtures && it.text("url")?.let(::localFixtureUrl) == true }
            .sortedByDescending { it.flag("default") }
            .map { row ->
                val url = row.text("url").orEmpty()
                val code = row.text("srclang").orEmpty().lowercase()
                PlaybackTrack(url, row.text("label")?.trim()?.takeIf { it.isNotEmpty() } ?: "Subtitles", LANGUAGES[code] ?: code.ifEmpty { "und" }, url)
            }.distinctBy { it.url }
        return ParsedProviderSources(listOf(ProviderStream(source, session.text("kind") ?: "hls", null, true)), subtitles, skip)
    }

    fun skip(bootstrap: JsonObject): ProviderSkip? {
        val skip = bootstrap["skip"] as? JsonObject ?: return null
        val op = skip["op"] as? JsonObject; val ed = skip["ed"] as? JsonObject
        return ProviderSkip(op?.number("start"), op?.number("end"), ed?.number("start"), ed?.number("end")).takeIf {
            it.introEnd?.let { end -> end > (it.introStart ?: 0.0) } == true ||
                it.outroStart?.let { start -> it.outroEnd?.let { end -> end > start } } == true
        }
    }

    private val LANGUAGES = mapOf(
        "ind" to "id", "tha" to "th", "chi" to "zh", "zho" to "zh", "kor" to "ko", "pol" to "pl",
        "tur" to "tr", "jpn" to "ja", "eng" to "en", "spa" to "es", "por" to "pt", "fre" to "fr",
        "fra" to "fr", "ger" to "de", "deu" to "de", "ita" to "it", "rus" to "ru", "ara" to "ar",
        "vie" to "vi", "may" to "ms", "msa" to "ms",
    )
}

object AniChanSharedParser {
    const val BASE = "https://anichan.to"

    fun availability(root: JsonObject): ProviderAvailability {
        val count = root.number("episodes")?.toInt() ?: 0
        if (count <= 0) error("AniChan has no entry for this title")
        val rows = (1..count).toSet()
        return ProviderAvailability(rows, if (root.flag("dubAvailable")) rows else emptySet())
    }

    fun sources(servers: JsonArray, baseUrl: String = BASE): ParsedProviderSources {
        val usable = servers.mapNotNull { it as? JsonObject }
            .filterNot { it.text("name").orEmpty().let { name -> name.startsWith("megaplay", true) || name.equals("vidhawk", true) } }
            .filter { !it.text("stream").isNullOrBlank() }
            .sortedBy { it.number("rank")?.toInt() ?: Int.MAX_VALUE }
        if (usable.isEmpty()) error("AniChan returned no playable server")
        fun absolute(url: String) = (if (url.startsWith("/")) "$baseUrl$url" else url).replace(" ", "%20")
        val streams = usable.mapIndexed { index, row -> ProviderStream(
            absolute(row.text("stream").orEmpty()), "hls",
            row.text("label")?.trim()?.trimStart('★')?.trim()?.takeIf { it.isNotBlank() }
                ?: row.text("name") ?: "Server ${index + 1}", index == 0,
        ) }
        val subtitles = (usable.first()["subtitles"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }.mapNotNull { row ->
            val url = row.text("url")?.takeIf { it.isNotBlank() }?.let(::absolute) ?: return@mapNotNull null
            val label = row.text("lang")?.takeIf { it.isNotBlank() } ?: "Subtitles"
            PlaybackTrack(url, label, language(label), url)
        }.distinctBy { it.url }
        return ParsedProviderSources(streams, subtitles, null)
    }

    private fun language(label: String): String = when {
        label.startsWith("eng", true) -> "en"
        label.startsWith("spa", true) -> "es"
        label.startsWith("por", true) -> "pt"
        label.startsWith("fre", true) || label.startsWith("fra", true) -> "fr"
        label.startsWith("ger", true) || label.startsWith("deu", true) -> "de"
        label.startsWith("ita", true) -> "it"
        label.startsWith("ara", true) -> "ar"
        label.startsWith("rus", true) -> "ru"
        label.startsWith("ind", true) -> "id"
        label.startsWith("kor", true) -> "ko"
        label.startsWith("jap", true) -> "ja"
        label.startsWith("chi", true) || label.startsWith("zho", true) -> "zh"
        else -> "und"
    }
}

internal fun JsonObject.text(name: String): String? = (this[name] as? JsonPrimitive)?.contentOrNull
private fun JsonObject.flag(name: String): Boolean = (this[name] as? JsonPrimitive)?.booleanOrNull == true
private fun JsonObject.number(name: String): Double? = (this[name] as? JsonPrimitive)?.doubleOrNull
internal fun localFixtureUrl(url: String): Boolean = Regex("^http://(?:127\\.0\\.0\\.1|localhost):[0-9]+(?:/|$)").containsMatchIn(url) && MediaSourcePolicy.validUrl(url)
