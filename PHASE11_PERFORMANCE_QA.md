# Phase 11 performance and QA

Phase 10 preflight passed. Merge `c17ec54` has the same tree as `98049bd`, which passed Android/TV and Apple checks in [run 44468879264](https://github.com/fawazorg/Anilili/actions/runs/44468879264). Phase 11 started from a clean, synchronized local main in a separate worktree.

## Baseline and ownership

Four agents owned separate paths. iOS owned PlaybackModel and LifecycleTests. Android/TV owned playback UI and its JVM regression. Shared owned catalog and history. Offline owned the iOS download engine and download tests. The lead reviewed integration and ran final checks.

The Phase 10 hosted run took 5m 06s for Android and 44m 52s for Apple. The Intel simulator job spent 8m on Debug framework linking and shared tests, 10m 41s on Swift build and simulator journeys, and 12m 22s linking Release frameworks. These are one run's CI step durations, not app latency measurements.

Android has a startup diagnostic on API 35+ and five-iteration macrobenchmarks for cold startup and warm TV D-pad frame timing. Linux had no connected device or Xcode. App startup, search and catalog latency, playback startup and buffering, download throughput, CPU, memory, battery, thermal behavior, and leak profiling are NOT TESTED. No elapsed-time improvement is claimed.

## Confirmed findings and changes

- iOS playback could leave its error state when late AVPlayer callbacks arrived for the same item. PlaybackModel now rejects those callbacks after failure, and Play requires a healthy item. The simulator regression injects a late notification and checks that reloading the media restores actual progress.
- Pausing during MP4 integrity verification could leave a staged file behind when the old finalizer lost ownership. The download engine now cleans up that job's file and receipt on pause. The new regression pauses at the verification boundary and checks disk and repository state.
- Android and TV embed fallback probes could commit a delayed observation after a page switch or after the bridge had delivered fresher data. The playback UI now binds the callback to the originating request and gives fresh bridge ticks precedence. JVM coverage exercises stale callbacks and bridge handoff.
- Catalog responses were parsed from text twice. AniList decoding now reuses the validated JSON tree, reducing full text parses from two to one. History snapshots now sort once instead of twice, retaining newer generation and sequence precedence for duplicates.

## Verification

- PASS: Phase 10 CI baseline, 29 local Python fixture and workflow tests, and 27 focused catalog and history JVM tests. The final integrated run passed 116 shared JVM tests, both Android debug builds, and 2,581 tests per Android flavor, including all three new probe tests. Five existing tests per Android flavor were skipped. The first integrated attempt failed during test compilation because an agent edit landed after main source compilation. The rerun used the stable final tree and passed.
- BLOCKED: Phase 11 hosted CI requires a published revision and manual dispatch. CI remains manual by repository choice.
- NOT TESTED: Phase 11 iOS Swift compilation, simulator integration and lifecycle tests, Release builds, and physical-device tests.

## Physical-device checklist for Phase 12

Run on a signed supported iPhone, an Android phone including API 22 coverage where available, and an Android TV with a remote. Record device and OS, exact build, provider and media format, sample count, and elapsed results. Use authorized media without recording credentials or signed source URLs.

- **NOT TESTED** — Repeat cold and warm launch five times. Measure time to usable catalog and first playback frame. On TV, repeat the existing D-pad sequence and capture frame timing and any focus loss.
- **NOT TESTED** — Play MP4 and HLS for an hour. Switch episodes, seek, change available tracks, interrupt audio, and background/foreground the app. Verify progression, resume, and resource release. Capture memory and CPU traces and compare thermal and battery readings under the same workload.
- **NOT TESTED** — Switch between Wi-Fi and cellular where available, then interrupt a queued download and restart. Confirm metadata, pause/resume behavior, cleanup, and offline playback with the origin unavailable. Repeat under storage pressure.
- **NOT TESTED** — Exercise live providers and supported header/cookie combinations. Record playback and recovery outcomes while redacting credentials. Confirm release diagnostics and storage contain no sensitive request data.

Phase 12 requires the Phase 11 hosted checks, signed device validation, and investigation of regressions measured against the same device and workload.
