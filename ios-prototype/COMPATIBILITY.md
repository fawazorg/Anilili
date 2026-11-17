# Phase 2 playback feasibility

This isolated prototype accepts already resolved URLs. It does not resolve provider pages, export, download, authenticate, or implement an anime catalog. Android is unchanged. Swift/AVPlayer execution is **pending macOS CI**; physical iPhone validation is **pending**. Linux media decoding establishes fixture validity, not AVPlayer compatibility. Provider conclusions below come from static repository inspection; no real provider media or resolver was executed. Phase 1 [run 44059106393](https://github.com/fawazorg/Anilili/actions/runs/44059106393) passed shared-core checks, including 12 iOS policy tests; those tests did not play video.

## Evidence and capability matrix

| Capability / pipeline | Repository evidence or fixture | Current result / boundary |
|---|---|---|
| Progressive H.264/AAC | `Fixtures/progressive.mp4`: original 12s, 160×90 Constrained Baseline / AAC LC | Linux ffprobe duration/codecs verified; ffmpeg decode passed. AVPlayer progress/seek/pause tests supplied; execution pending. |
| Standard HLS MPEG-TS | `Fixtures/hls/index.m3u8`, six 2s segments | Linux ffmpeg decode passed. AVPlayer playback progression test pending CI. |
| Alternate audio / WebVTT | `hls/master.m3u8`: English/French sine tones, English captions | Fixture declarations present. Simulator track discovery/selection pending; audible language/content and caption rendering need device review. |
| Cookies / headers / redirects | `PlaybackService.mediaRequestHeaders`, Android HTTP factories; PaheBridge cookies | Prototype only uses documented AVURLAsset options. Arbitrary Referer/Origin/Authorization forwarding is unsupported; no claim that successful top-level fetching propagates credentials to segments/keys or redirected hosts. No private cookies committed. |
| Kwik HLS | `KwikPlaylistDataSource.rewriteKwikPlaylistIvs` | Android inserts per-segment AES-128 IV derived from filename because implicit sequence IV differs. Direct untreated AVPlayer URL cannot be assumed correct, especially mid-stream seek. Adapter and authorized synthetic encrypted fixture required before provider parity. |
| UniqueStream key | `UniqueStreamKeyDataSource.uniqueStreamKeyBytes` | Android synthesizes key from active playlist marker, intercepting key.bin. No equivalent iOS implementation; do not claim direct playback or port this access-sensitive path without authorization review. |
| Flixcloud playlists / segments | `FlixcloudPlaylistDataSource` | Android transforms keyed playlist/PNG/WebP-wrapped responses. Ordinary AVPlayer fetching does not execute these wrappers. Unsupported in prototype. |
| Browser-assisted sources | `PaheBridge`: WebView, CookieManager, evaluateJavascript | WKWebView resolution and cookie synchronization not implemented. Provider URLs requiring browser challenges remain unverified. |
| SubRip / ASS / SSA subtitles | `SubtitleCueTimes` parses cue timing/text; Android Media3 renders | Prototype does not implement external subtitle conversion, ASS styling, or timing-offset parity. WebVTT track selection alone does not establish parity. |
| Playback engine / lifecycle | `PlaybackService`: custom load control, custom sources, cache, MediaSession, audio focus, seek/resume | Swift prototype exercises foreground AVPlayer controls and explicit cancellation only. Android buffers, cache, offline recovery and background behavior are not transplanted. |
| DASH / uncommon codecs / DRM | No licensed fixture in this scope | Unsupported/unverified. No DRM or access-control bypass. Alternative engine decision requires authorized failing samples and device evidence. |

Documented AVURLAsset request options: [cookies](https://developer.apple.com/documentation/avfoundation/avurlassethttpcookieskey) and [User-Agent](https://developer.apple.com/documentation/avfoundation/avurlassethttpuseragentkey). Apple documents that HLS requests can target different paths/hosts and cookies inapplicable to the asset URL are excluded; passing cookies is not a general cross-origin credential solution.

## Reproducible fixtures

All audio/video is generated from FFmpeg `testsrc2` and `sine`; captions and playlists are original text. No provider media, expiring URLs, tokens or cookies are included. Run `bash ios-prototype/Fixtures/generate.sh` with FFmpeg/libx264/AAC support to regenerate binaries (byte identity can vary by FFmpeg version). Existing `master.m3u8`, subtitle playlist and VTT are hand authored; the VTT timestamp map matches FFmpeg MPEG-TS start 1.4s. Automated tests serve these files from an ephemeral loopback HTTP server with range responses, avoiding external provider/network availability. Linux validation used ffprobe and complete ffmpeg decode of MP4 and HLS master; this is not simulator validation.

## Decision gate

Do not begin a full Phase 3 catalog/shared-data slice on the evidence currently available. First execute macOS CI and inspect actual time progression, seek/pause and track-selection results, then run an authorized provider matrix on a physical iPhone: direct progressive, standard HLS, header/cookie-gated HLS, redirects, explicit-IV HLS and browser-resolved media. Include mid-stream seek/resume, interruption/network transitions, hardware decoding, background playback, battery/thermal behavior and subtitles. Direct AVPlayer can be evaluated with this harness; the existing provider transformation and browser paths are unresolved adapter work, not evidence that an alternative engine is already necessary.

## Running the harness

On macOS with Xcode 16.4, open `PlaybackPOC.xcodeproj` and select the shared `PlaybackPOC` scheme and an iOS 18 simulator. Start `python3 ios-prototype/ci/serve_fixtures.py` from the repository root. Load `http://127.0.0.1:8765/progressive.mp4` or `http://127.0.0.1:8765/hls/master.m3u8`, then play. Run Product → Test for the eight XCTest cases. HTTPS test URLs may also be supplied manually; optional header JSON accepts only `User-Agent`. Cookies are an adapter-level input, without credential storage or an account UI. Header/cookie propagation across redirects and HLS child requests is unverified.

The separate `iOS Playback Proof of Concept` workflow builds and tests this harness on `macos-15-intel`, retaining logs and xcresult. Its success requires every XCTest to pass; compilation alone is insufficient. No new shared contract is needed for this already-resolved-URL experiment. The existing KMP framework is linked separately in CI, without adding an artificial Swift dependency.
