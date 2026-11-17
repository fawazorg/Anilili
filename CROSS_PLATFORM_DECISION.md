# Anilili — Cross-Platform Architecture Decision

### 1. Executive Decision

**Choose incremental Kotlin Multiplatform business-logic extraction, retaining Android Compose and Media3, with a SwiftUI iOS application and native playback adapters.**

This is a repository-specific risk decision, not a claim that Kotlin automatically makes existing code portable. The app's valuable behavior lives in Android services, provider-specific media data sources, browser bridges, persistence, and TV interaction as well as Kotlin algorithms. Preserve that implementation while establishing small portable boundaries.

Compose Multiplatform is the strongest alternative: it could reduce duplicated screen work. It does not eliminate the difficult provider, download, or playback adaptations, and moving existing screens would also require disentangling Android dependencies. Revisit selected shared screens after proving iOS media feasibility. Flutter provides insufficient compensating benefit to justify translating existing Kotlin policies and rebuilding TV behavior.

Assessment baseline: local commit `5367d00`, version 0.1.85; initial working tree clean. Static inspection and official documentation research only. No builds, tests, provider requests, device benchmarks, or migration changes were performed. This report is the sole created file. Findings establish implementation presence, not current operational success.

### 2. Repository Findings

Paths below are relative to the repository root; `K/` abbreviates `app/src/main/java/com/anilili/`. Symbols and paths identify inspected evidence.

| Area | Confirmed evidence and architectural consequence |
|---|---|
| Modules | `settings.gradle.kts` includes only `:app` and `:benchmark`; root name remains `MiruroNative`. No existing shared KMP module. Package folders are not independent module boundaries. |
| Build | `app/build.gradle.kts`: mobile/TV flavors, shared application ID, API 22 minimum, target/compile 36, JVM 17, ARM splits, R8 and baseline profiles. Preserve signing, package identity, upgrade compatibility, and legacy Fire TV support. |
| Versions | `gradle/libs.versions.toml`: Kotlin 2.1.21, AGP 8.10.1, Compose BOM 2024.12.01, Media3 1.8.1, OkHttp 4.12.0. Several dependency pins explicitly preserve API 22. A framework/toolchain uplift is a separate compatibility project. |
| Composition | `K/data/AppGraph.kt: AppGraph.init` constructs clients/cache using Context, ActivityManager, DNS and diagnostics. `MiruroRepository.kt` imports concrete providers, account and library state. Neither is immediately common-code-ready. |
| TV | `K/ui/adaptive/TvFocusTarget.kt` uses FocusRequester and preview key handling; `TvWebRemoteFocus.kt` and `DpadLongPress.kt` provide TV-specific interaction surfaces. TV is existing functionality, not a future responsive-layout exercise. |
| Flavor separation | `app/src/tv/` supplies Cast implementations; `mobileImplementation(media3.cast)` scopes Cast to mobile. Keep dedicated TV composition and remote behavior; adopting a new TV UI library is not required for KMP. |
| Playback | `K/playback/PlaybackService.kt:328` creates ExoPlayer with custom media sources, subtitle renderers and adjustable load control; `:369` creates MediaSession. It handles audio focus/noisy output and Cast routing. Preserve this service. |
| Provider media | PlaybackService wraps sources in `KwikPlaylistDataSource`, `UniqueStreamKeyDataSource`, and `FlixcloudPlaylistDataSource`. These transformations make a generic cross-platform video plugin an inadequate replacement. |
| Formats | HLS playlist/key processing and progressive-stream buffer handling are implemented. DASH dependency exists, but this assessment does not establish an exercised DASH provider path. Neither dependency declarations nor URL extensions prove codec support. |
| Subtitles | `K/playback/SubtitleCueTimes.kt: parseSubtitleCueTimes` handles VTT/SRT and ASS/SSA cue timing for synchronization; it explicitly discards styling and is not a renderer. `SubtitleDelay` and track-selection code need separate iOS rendering validation. |
| Audio and controls | PlaybackService configures 10-second seeks, audio attributes, sleep timer and media controls. `EpisodeDownloads.kt: categoryAudioParameters`, `addAllTextTrackSelections` implement audio/text selection for downloads. Tests cover quality, gestures, audio switching and TV seeking; existence does not establish passing behavior. |
| Downloads/cache | `K/playback/EpisodeDownloads.kt` uses Media3 DownloadManager/DownloadHelper, SimpleCache, resolving data sources, notifications and track selections. Media3 database/cache state cannot simply become an iOS offline store. |
| Export | `K/playback/EpisodeExport.kt` runs Transformer with `MonotonicAudioMuxer`, writing MP4 through Android storage paths; `EpisodeExportWorker.kt` schedules WorkManager jobs and coordinates resource pressure. Offline playback and exporting portable files are distinct requirements. |
| Persistence | `K/data/library/LibraryStore.kt` persists JSON in SharedPreferences and exposes StateFlow; `SettingsStore.kt` uses preferences DataStore with Android/device dependencies. This is not an existing Room/SQLDelight domain database to move wholesale. |
| Authentication | `K/data/auth/SecureTokenStore.kt` uses Android Keystore, AES/GCM and SharedPreferences; key/AAD identity preserves logins. Auth managers exist for AniList, MAL, Simkl, OpenSubtitles and Discord. iOS requires its own secure store and callback lifecycle. |
| Synchronization | LibraryStore directly references account state and ListProgressSyncWorker; `K/data/remote/ListProgressSyncWorker.kt` uses Android WorkManager. Separate merge/retry policy from scheduling and durable storage before sharing it. |
| API integrations | AppGraph wires AniList, AniZip, AniSkip, Konoha, MAL, OpenSubtitles and TMDB clients. OkHttp, DNS/TLS policies and disk cache are concrete dependencies; serializers and request/response policies are better extraction units than complete clients. |
| Browser/provider execution | `K/data/remote/PaheBridge.kt` uses CookieManager and evaluateJavascript; `K/ui/PaheResolverWebView.kt` creates/releases a real Android WebView. Browser lifetime currently intersects Compose UI lifetime. iOS needs a separately validated browser adapter. |
| Historical dependency trap | `K/data/remote/OkHttpPipe.kt` implements the pipe using HTTP and explicitly describes removal of its former browser engine. Gecko/libxul packaging comments in the build file do not establish active GeckoView usage. |
| Services/permissions | `app/src/main/AndroidManifest.xml` declares foreground media/data sync, notifications, boot, package installation and legacy storage access. These capabilities require platform-specific lifecycle/distribution decisions. |
| Coupling | EpisodeDownloads imports `ui.watch.categoryAudioDecision` and navigation routes; SubtitleCueTimes combines parsing with Android URI access and AppGraph networking. Even ostensibly reusable policy files need dependency-level review. |
| Tests | `app/src/test/` contains policy/parser tests and parity fixtures; `app/src/androidTest/` contains provider, playback, download/export and UI probes. `benchmark/` contains TV performance benchmarks and baseline-profile generation. No test results are asserted here. |
| Tooling | Java is on PATH; xcodebuild, flutter and kotlinc were not found on PATH. Gradle wrapper is present. `preBuild` can run `syncParityCorpus`, writing test resources from a sibling checkout: even a diagnostic build would violate this assessment's constraints. |

**Shareability:** pure algorithms and serializable values are candidates; repository orchestration requires interfaces and removal of global state. Android UI, Media3, WorkManager, storage URIs, Keystore, browser cookies, notifications and installation stay behind adapters. Java imports, clocks, locale behavior, regex helpers and cryptography must be audited individually; Kotlin source is not proof of Kotlin/Native compatibility.

### 3. Architecture Comparison

Qualitative judgments concern this repository. No measured runtime comparison or staffing-based schedule is available.

| Criterion | A — Flutter/Dart | B — KMP + native UI | C — Compose Multiplatform | D — Independent SwiftUI client + shared protocol fixtures |
|---|---|---|---|---|
| Code reuse | Rewrite Kotlin/UI or maintain native bridge islands | Retain Android; extract selected Kotlin | Retain Kotlin plus potentially reusable composables after cleanup | Retain Android; duplicate iOS domain logic |
| Migration effort | Largest replacement scope | Incremental, moderate extraction plus substantial iOS work | Extraction plus UI/toolchain adaptation; potentially less new UI | Fastest isolation, but repeated provider/policy work |
| Maintenance | Dart plus Kotlin/Swift media bridges | Shared policy, two native UIs | Shared UI/policy, platform interop still required | Two implementations can diverge |
| Performance/memory | Requires profiling composition and bridges | Least disruption to existing Android tuning | Requires profiling shared UI and native surfaces | Native surfaces; duplicated optimization work |
| Playback/hardware | Native engine/plugin customization remains | Preserve Media3; native iOS engine | Same native engine requirements as B | Same native engine requirements as B |
| Codecs/subtitles/audio | Framework does not create decoder parity | Capability-driven adapters and test corpus | Same constraints as B | Same constraints as B |
| TV focus | Rebuild and verify remote navigation | Preserve existing focus behavior | Preserve dedicated Android TV UI | Preserve existing Android TV |
| iOS restrictions | Native browser/background/storage integration | Explicit native adapters | Native adapters embedded in shared UI | Direct native implementation |
| Offline/export | Reimplement or bridge existing pipeline | Preserve Android; design iOS pipeline | Same as B | Separate pipeline and policy |
| UX | Shared visual system; platform adjustments | Native phone/tablet idioms; duplicated layout | Highest visual reuse; iOS interaction work | Native UX, duplicated feature work |
| Testing | Dart + native + bridge/device suites | Common tests + adapter/device/UI suites | Common tests + shared UI/native integration suites | Parity fixtures + two complete suites |
| Ecosystem risk | Plugin feature gaps and upgrade coordination | Kotlin/Native/toolchain and Swift interop | Adds Compose/toolchain/native-view compatibility | Lowest framework coupling; highest policy drift |
| Extensibility | Dart ecosystem and custom native bridges | Platform ports behind stable contracts | Shared screens can expand later | Every policy change usually implemented twice |
| Android regression | Highest if replacing app | Lowest with one extraction at a time | Higher if existing screens/toolchain move together | Very low initially |

Flutter platform views have documented composition tradeoffs; this is a profiling requirement, not evidence that Flutter is inherently slow ([Flutter documentation](https://docs.flutter.dev/platform-integration/android/platform-views)).
Compose Multiplatform is documented as stable on iOS and supports SwiftUI interoperation; rejecting it as immature would be unjustified ([Kotlin FAQ](https://kotlinlang.org/docs/multiplatform/faq.html), [SwiftUI integration](https://kotlinlang.org/docs/multiplatform/compose-swiftui-integration.html)).
Option D is defensible for an early isolated playback prototype, but existing parity fixtures already illustrate the burden of maintaining equivalent behavior across implementations. Use it as a feasibility technique, not the long-term primary architecture.

### 4. Recommended Architecture

Introduce boundaries gradually; these are proposed modules, not existing ones:

- `:shared-core`: deterministic policies, domain values, portable serialization; no Context, Media3, UI, global AppGraph or platform clocks.
- `:shared-data` later: provider parsing, API contracts, repository orchestration and synchronization policies through injected HTTP, persistence, clock and credential interfaces. Preserve Android OkHttp initially; evaluate a multiplatform HTTP implementation only when needed.
- `:app`: current mobile/TV flavors, Compose, ViewModels, Android composition root, Media3, WorkManager, DataStore/SharedPreferences, browser and platform integrations. Extract Android adapter modules only when boundaries are proven.
- `iosApp`: SwiftUI for iPhone/iPad, native navigation/accessibility, secure credentials, browser/auth callbacks, media controls, storage and transfer lifecycle. Consume a small shared framework API with explicit cancellation/error semantics.
- `:benchmark`: retain Android performance regression coverage. Add iOS device performance coverage in the implementation phase.

Define shared playback intent/state, stream identity, required headers, selected audio/text tracks and capability results. Do not expose MediaItem, Uri, AVPlayerItem or UI objects across shared interfaces. Platform adapters own engine lifetimes, surfaces and callbacks.

**Playback strategy:** preserve Media3 unchanged initially. Prototype AVPlayer against representative actual provider outputs before committing to full iOS delivery. Test HLS/progressive media, redirects, cookies/headers, encryption/key requests, seek/resume, audio switching and subtitle timing/styling. Treat DASH, unusual containers/codecs and ASS rendering as explicit compatibility questions. Consider a maintained alternative engine only for demonstrated gaps, accounting for hardware decode, power, binary size and licensing review.

Media3 normally uses device decoders, so codec/hardware support is device-dependent ([Android supported formats](https://developer.android.com/media/media3/exoplayer/supported-formats)). No framework choice guarantees equal decoding or styled subtitle behavior.

For iOS offline HLS, evaluate AVAssetDownloadURLSession; for suitable file transfers, background URLSession. Neither is a direct replacement for arbitrary Media3 segment caches or unrestricted worker execution ([Apple HLS downloads](https://developer.apple.com/documentation/avfoundation/avassetdownloadurlsession), [background transfers](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)). Keep export requirements separate and gate support by tested formats.

Preserve Android persisted schemas, profile isolation, token identifiers, pending sync and download indices. Add iOS storage adapters before considering any cross-platform storage migration. Share serialized domain semantics, not engine cache files.

### 5. Migration Roadmap

| Phase | Goal and deliverable | Verification/acceptance gate | Risk and rollback |
|---|---|---|---|
| 1 — Small extraction | Shared-core with one deterministic download policy; Android calls it | Existing behavior tests pass on JVM and iOS simulator; both Android flavors build with API 22 retained | Toolchain/internal visibility changes; revert one extraction, no stored-data changes |
| 2 — iOS feasibility gate | Minimal native iOS catalog-to-playback prototype; representative provider/media corpus and capability matrix | Physical iPhone/iPad playback, seek/resume, tracks, challenge/cookie flow and one background offline download demonstrated; record unsupported cases | Browser/media parity may fail; pause iOS expansion and retain working Android |
| 3 — Shared vertical slice | Portable catalog models/parser and one repository use case through injected transport; SwiftUI browse/details | Identical fixture outputs, error/cancellation tests, Android feature parity and iOS navigation/accessibility | Network semantics differ; retain Android adapter and switch back per use case |
| 4 — Library/auth/sync | Shared merge/idempotency policies; native storage/credential adapters and account UI | Existing Android data survives upgrade; offline edits, retries, account/profile switches and conflict fixtures pass | Data loss/cross-account writes; additive schemas, backup/restore verification, old reader compatibility |
| 5 — Media/offline parity | Broader providers, native download management/export and playback controls | Approved codec/container/track matrix; interruption, restart, disk-full, expiration and airplane-mode playback tests | OS suspension and provider expiry; capability-gate features, retain Android implementation |
| 6 — Release qualification | Phone/tablet/TV regression suites and staged iOS release candidate | D-pad/back/focus restoration, low-RAM Fire TV, background audio, accessibility, memory/startup and playback-stall results compared with baseline | Toolchain or performance regression; staged rollout and previous compatible release available |

Before phase 1, record baseline results in a separately authorized implementation session. Test mobile and TV variants, release/R8 behavior, and representative API-22 hardware. Builds here were deliberately not run.

Measure startup, peak memory, time to first frame, seek latency, dropped frames, download recovery and battery/thermal behavior on named devices using the same corpus. Establish acceptable regression thresholds from that baseline rather than inventing framework scores. Provider live tests must be separated from deterministic tests so network outages do not masquerade as architectural regressions.

Do not combine extraction, dependency modernization, UI redesign and persistent-schema changes in one rollout. Apple development requires access to macOS/Xcode and physical devices; local Linux inspection cannot validate that toolchain.

### 6. Next Implementation Task

**Extract only `DownloadStallTracker` into a minimal KMP `:shared-core` module.**

- Source: `app/src/main/java/com/anilili/playback/DownloadStallTracker.kt`; tests: `app/src/test/java/com/anilili/playback/DownloadStallTrackerTest.kt`.
- Why: the inspected class has no imports or platform APIs, receives time explicitly, and already specifies meaningful regressions including trickle progress. This is smaller and safer than moving a repository, parser mixed with I/O, or persistence layer.
- Scope: configure Android/JVM-consumable and iOS targets; move this policy and adapt its tests to common testing; keep the Android download service, sampling inputs and thresholds unchanged. Resolve its current `internal` visibility with the smallest explicit module API.
- Affected build files: root/plugin configuration as necessary, `settings.gradle.kts`, `app/build.gradle.kts`, and the new module. Do not upgrade unrelated dependencies or move download execution.
- Prerequisites: explicit implementation authorization, compatible KMP/AGP/Kotlin version selection preserving API 22, baseline Android tests, and macOS/Xcode access for actual Native verification.
- Acceptance: no duplicate policy implementation; unchanged trickle/healthy-progress/reset/timeout behavior; common tests pass on JVM and iOS simulator; mobile and TV build and relevant download tests pass; no persistence or UI behavior changes.
- Native verification must be reported as pending if no Apple runner is available; JVM success alone does not complete this milestone.
- Rollback: restore the original class/test and remove the module dependency; no user data migration is involved.

### 7. Open Questions

1. Which providers and media combinations are mandatory for first iOS release, including ASS styling, uncommon audio codecs, export, Cast/external-player behavior and background playback?
2. What iOS distribution route and content/service permissions apply? Store acceptance and provider availability are unverified delivery dependencies; Android APK self-update behavior cannot define the iOS distribution design.
3. Can representative provider cookies, headers, JavaScript challenges and playlist/key rewrites work reliably with iOS browser/network/media APIs? The repository cannot establish this.
4. What are the minimum supported iOS devices/versions, and is macOS/Xcode/device CI available?
5. What SwiftUI expertise and ongoing UI maintenance capacity exist? Strong Kotlin-only staffing could justify reconsidering Compose Multiplatform after the media feasibility gate.
6. Which account/profile conflict rules and offline/export guarantees must remain identical across devices? Existing Android behavior should be captured as fixtures before implementation changes.
