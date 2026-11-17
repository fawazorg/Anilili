# iOS catalog-to-playback feasibility

The merged Phase 3 baseline passed [KMP checks](https://github.com/fawazorg/Anilili/actions/runs/44074127835) and [18 Swift catalog/playback tests](https://github.com/fawazorg/Anilili/actions/runs/44074127972), including MP4/HLS time progression. Phase 4 connects that catalog and player through shared episode listing/source resolution and an explicitly labeled original demo provider. **Phase 4 Swift build, new simulator journey tests, and UI automation are not validated on Linux. Physical iPhone and real-provider playback remain pending.**

The demo is not evidence that AniList metadata supplies episode media. Live AniList catalog results must not be assigned the synthetic demo episodes. No production provider resolver, authentication, download, or export migration is included. Provider conclusions below come from static repository inspection; no real provider media or resolver was executed.

## Evidence and capability matrix

| Capability / pipeline | Repository evidence or fixture | Current result / boundary |
|---|---|---|
| Progressive H.264/AAC | `Fixtures/progressive.mp4`: original 12s, 160×90 Constrained Baseline / AAC LC | Linux ffprobe duration/codecs verified; ffmpeg decode passed. Baseline simulator progress/seek/pause tests passed. Connected episode-selection journey execution remains pending Phase 4 CI. |
| Standard HLS MPEG-TS | `Fixtures/hls/index.m3u8`, six 2s segments | Linux ffmpeg decode passed. Baseline simulator playback progressed. Connected HLS journey execution remains pending Phase 4 CI. |
| Alternate audio / WebVTT | `hls/master.m3u8`: English/French sine tones, English captions | Fixture declarations present. Baseline simulator track discovery/selection passed; audible language/content and caption rendering need device review. |
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

## Phase 4 decision gate

Do not label the new journey complete until macOS CI executes all required tests, including playback progression after episode resolution, cancellation, cleanup after returning, and the separate UI journey test. Model integration tests do not establish real UI navigation automation; a separate `JourneyUITests` target is provided to exercise visible navigation and playback progress, with execution pending macOS CI. The existing required catalog and playback suites remain active, and CI rejects missing/empty integration or UI journey suites, skipped tests, or incomplete results.

Before expanding real provider support, run an authorized provider matrix on a physical iPhone: direct progressive, standard HLS, header/cookie-gated HLS, redirects, explicit-IV HLS and browser-resolved media. Include seek/resume, interruptions/network transitions, hardware decoding, background/foreground behavior, battery/thermal behavior and subtitles. Existing provider transformations and browser paths remain adapter work, not evidence that an alternative engine is already necessary. Phase 5 should be scoped only after reviewing these results; no offline downloads, account migration, or storage changes are implemented here.

## Running the harness

On macOS with Xcode 16.4, open `PlaybackPOC.xcodeproj` and select the shared `PlaybackPOC` scheme and an iOS 18 simulator. Start `python3 ios-prototype/ci/serve_fixtures.py` from the repository root. Load `http://127.0.0.1:8765/progressive.mp4` or `http://127.0.0.1:8765/hls/master.m3u8`, then play. Run Product → Test for all catalog, playback, and journey XCTest cases. HTTPS test URLs may also be supplied manually; optional header JSON accepts only `User-Agent`. Cookies are an adapter-level input, without credential storage or an account UI. Header/cookie propagation across redirects and HLS child requests is unverified.

The existing `iOS End-to-End Experience` workflow builds and tests the app on `macos-15-intel`, retaining logs and xcresult. Its success requires every XCTest to pass; compilation alone is insufficient. The app consumes the shared KMP catalog and episode/source contracts, with platform media objects kept in Swift. The bundled synthetic demo and live AniList metadata are separate modes. MP4 can use the bundled original fixture; HLS journey testing uses the loopback server. `Fixtures/invalid.mp4` is original plaintext deliberately passed as media to exercise player failure handling.
