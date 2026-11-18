package com.anilili.data.remote

import com.anilili.data.model.SkipTimes
import com.anilili.data.model.SourcesResult
import com.anilili.data.model.StreamItem
import com.anilili.data.model.SubtitleItem
import com.anilili.provider.ParsedProviderSources

/** Only platform model conversion lives here; provider parsing is shared with iOS. */
internal fun ParsedProviderSources.toAndroidSources() = SourcesResult(
    streams = streams.map { StreamItem(it.url, it.type, it.quality, null, null, it.active, null, null) },
    subtitles = subtitles.map { SubtitleItem(requireNotNull(it.url), it.label, it.language ?: "und") },
    skip = skip?.let { SkipTimes(it.introStart, it.introEnd, it.outroStart, it.outroEnd) },
    download = null,
)
