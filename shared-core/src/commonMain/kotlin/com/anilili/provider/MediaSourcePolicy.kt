package com.anilili.provider

import com.anilili.episodes.PlaybackSource
import com.anilili.episodes.PlaybackRedirectPolicy

/** Portable URL and capability checks; no request values are included in diagnostic text. */
object MediaSourcePolicy {
    fun validUrl(value: String, allowFixtures: Boolean = false): Boolean {
        if (value.any { it <= ' ' || it == '\\' }) return false
        // Bundled fixtures are explicit demo assets, never inferred from a live AniList title.
        if (allowFixtures && (value == "fixture://progressive.mp4" || value == "fixture://hls/master.m3u8" || value == "fixture://invalid.mp4")) return true
        val match = Regex("^https?://([^/?#]+)(?:[/?#].*)?$").matchEntire(value) ?: return false
        val authority = match.groupValues[1]
        // No credentials, malformed port, or empty host may cross the provider boundary.
        val parts = Regex("^(\\[[0-9A-Fa-f:]+\\]|[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)(?::([0-9]{1,5}))?$").matchEntire(authority)
            ?: return false
        val port = parts.groupValues[2]
        return (port.isEmpty() || port.toInt() in 1..65535) &&
            (parts.groupValues[1].startsWith("[") || parts.groupValues[1].split('.').all { it.isNotEmpty() && !it.startsWith("-") && !it.endsWith("-") })
    }


    fun validHeaders(headers: Map<String, String>): Boolean = headers.all { (name, value) ->
        name.isNotEmpty() && name.all { it.isLetterOrDigit() && it.code < 127 || it in "!#$%&'*+-.^_`|~" } &&
            value.none { it < ' ' || it == '\u007f' }
    }

    fun resolveUrl(base: String, reference: String): String? {
        if (Regex("^[A-Za-z][A-Za-z0-9+.-]*:").containsMatchIn(reference)) return reference.takeIf { validUrl(it) }
        if (!validUrl(base) || reference.isBlank()) return null
        val root = Regex("^(https?://[^/?#]+)").find(base)?.value ?: return null
        val scheme = base.substringBefore(":")
        if (reference.startsWith("//")) return (scheme + ":" + reference).takeIf { validUrl(it) }
        val path = base.removePrefix(root).substringBefore('?').substringBefore('#').ifEmpty { "/" }
        val combined = when {
            reference.startsWith("/") -> reference
            reference.startsWith("?") -> path + reference
            reference.startsWith("#") -> base.removePrefix(root).substringBefore('#') + reference
            else -> path.substringBeforeLast('/', "") + "/" + reference
        }
        if (reference.startsWith("?") || reference.startsWith("#")) {
            return (root + combined).takeIf { validUrl(it) }
        }
        val suffix = combined.dropWhile { it != '?' && it != '#' }
        val rawPath = combined.takeWhile { it != '?' && it != '#' }
        val parts = rawPath.split('/')
        val segments = mutableListOf<String>()
        for ((index, part) in parts.withIndex()) when (part) {
            "." -> if (index == parts.lastIndex) segments += ""
            ".." -> {
                if (segments.size > 1) segments.removeAt(segments.lastIndex)
                if (index == parts.lastIndex) segments += ""
            }
            else -> segments += part
        }
        return (root + segments.joinToString("/") + suffix).takeIf { validUrl(it) }
    }

    /** Public AVURLAsset options cannot guarantee arbitrary headers or strict redirect control. */
    fun appleUnsupportedReason(source: PlaybackSource, nowMs: Long): String? = when {
        source.expiresAtMs?.let { it <= nowMs } == true -> "Playback source has expired; resolve it again"
        source.requirements.isNotEmpty() -> "Playback source requires unsupported capabilities"
        (source.audioTracks + source.subtitleTracks).any { it.url != null } -> "External track adapters are unsupported by AVPlayer"
        source.redirectPolicy != PlaybackRedirectPolicy.SYSTEM -> "Strict media redirect control is unsupported by AVPlayer"
        source.headers.keys.any { !it.equals("User-Agent", ignoreCase = true) } -> "Required media headers are unsupported by AVPlayer"
        else -> null
    }
}
