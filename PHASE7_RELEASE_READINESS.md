# Phase 7 — iOS release readiness

## Baseline and scope

**PASS:** PR #6 was already merged normally into `main` at
`04b5b8f23e6a239f87d946f75af619963e9763b8`. Its Android and Apple checks succeeded
([run 44237893202](https://github.com/fawazorg/Anilili/actions/runs/44237893202)).
Local `main` matched `origin/main` and was clean before creating
`feature/ios-phase7-production-readiness`. Publication and CI execution were subsequently authorized.

Three agents handled exclusive lifecycle models/tests, accessibility/diagnostics,
and Apple build/CI files. The lead reviewed integration and ran Linux validation.
Existing shared catalog, episode resolution, watch-history rules, native atomic
history storage, and AVPlayer are reused. Android source, Media3, API 22, TV focus,
authentication, downloads, and persistence formats are unchanged.

## Confirmed gaps addressed

- Playback now pauses and flushes progress on audio interruptions, headphone
  removal, and background entry. Foregrounding never automatically resumes video.
  A pending resume seek cannot start background playback. Audio activation belongs
  to one player; an idle player cannot deactivate another player's audio session.
- Memory warnings release media and cancel obsolete resolution. Repeated scene and
  application background callbacks preserve pending catalog retry state. Observer,
  seek, asset-loading, and player cleanup includes deinitialization.
- Diagnostics accept fixed categories/events and bounded numeric status codes only.
  A bounded memory ring and local OSLog contain no request URLs, cookies, tokens,
  arbitrary error descriptions, analytics identifiers, or upload mechanism.
- Existing screens gain labelled controls, 44-point touch targets, adaptive player
  button layout, multiline titles, and a decorative missing-artwork fallback.
- The previous simulator-only configuration now supports iPhone arm64 through a
  static `iosArm64` SharedCore framework. Intel simulator remains `iosX64`.
  Release now links `releaseFramework`, rather than Debug output. Deployment stays
  iOS 17.0 and the bundle identifier stays `org.anilili.playbackpoc`.

No background audio capability or global ATS exception was added. Existing narrow
local-fixture networking exceptions remain. Unsupported arbitrary provider headers,
strict HLS redirect control, and external-track requirements remain explicit.

Changed files:

- `ios-prototype/App/`: `PlaybackModel.swift`, `ProviderPlaybackModel.swift`,
  `JourneyModel.swift`, `CatalogModel.swift`, `WatchHistoryModel.swift`,
  `JourneyView.swift`, `CatalogView.swift`, `PlaybackPOCApp.swift`; new
  `LocalDiagnostics.swift` and `PrivacyInfo.xcprivacy`.
- New `ios-prototype/Tests/LifecycleTests.swift`, `Tests/DiagnosticsTests.swift`,
  and `UITests/AccessibilityUITests.swift`.
- `ios-prototype/PlaybackPOC.xcodeproj/project.pbxproj` and its shared
  `xcshareddata/xcschemes/PlaybackPOC.xcscheme`.
- `ios-prototype/ci/verify_results.py`, `test_verify_results.py`; new
  `verify_release_settings.py`, `test_release_settings.py`.
- `shared-core/build.gradle.kts`, `.github/workflows/kmp-ci.yml`, and this report.

## Validation

| Check | Status | Evidence / boundary |
|---|---|---|
| Phase 6 merge and hosted checks | PASS | Merge SHA and run above; this does not validate Phase 7. |
| Shared JVM tests | PASS | Fresh `:shared-core:jvmTest --rerun`: 67 tests, zero failures/skips. |
| Android mobile and TV unit tests | PASS | Each flavor: 2,581 total, 2,576 passed, five pre-existing live probes skipped; zero failures/errors. Skipped live probes are NOT TESTED. |
| Android mobile and TV debug builds | PASS | Both `assembleMobileDebug` and `assembleTvDebug` succeeded locally. |
| CI Python tests | PASS | 15 tests: fixture HTTP behavior, missing/skipped-result rejection, Release SDK/framework validation. |
| Apple task names | PASS | Gradle enumerated `linkDebugFrameworkIosArm64`, `linkReleaseFrameworkIosArm64`, `linkReleaseFrameworkIosX64`. |
| Phase 7 Native/Swift compilation and simulator tests | NOT TESTED | Linux has no Xcode or iOS simulator; GitHub execution is pending. |
| Release simulator/device builds | NOT TESTED | CI now requires both unsigned Release builds and validates resolved SDK, architecture, framework path, bundle identity, and copied privacy manifest. |
| Signed device build / archive / TestFlight | BLOCKED | Apple signing team, certificates/provisioning and distribution setup are unavailable. |
| Physical iPhone and live providers | NOT TESTED | Simulator fixtures do not establish hardware or live-provider compatibility. |

Linux command (JDK 17 and existing Android SDK configured):

```sh
./gradlew :shared-core:tasks --all :shared-core:jvmTest \
  :app:testMobileDebugUnitTest :app:testTvDebugUnitTest \
  :app:assembleMobileDebug :app:assembleTvDebug \
  -x :app:syncParityCorpus --offline --console=plain --no-configuration-cache
./gradlew :shared-core:jvmTest --rerun --offline --console=plain
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s ios-prototype/ci -p 'test_*.py'
```

`syncParityCorpus` was excluded to avoid modifying generated test resources from a
sibling checkout. No generated or user data was deleted. Workflow YAML, shell and
embedded Python syntax, plist/scheme parsing, all 71 Xcode object references, and
`git diff --check` passed. Gradle reports the expected disabled Apple targets on
Linux; Native linking was not executed here. Existing deprecation warnings remain.

New Apple tests are nine `LifecycleTests`, three `DiagnosticsTests`, and
`AccessibilityUITests.testDemoJourneyControlsRemainAccessibleAtLargestDynamicTypeInDarkMode`.
Lifecycle tests require real original MP4 progression before interruption/route/
memory assertions, exercise pending resume, exclusive audio ownership, stale items,
late provider callbacks, and duplicate background notifications. Existing playback,
provider HTTP propagation, history restart, stale-session, and journey tests remain.
The result guard requires all 59 discovered tests to execute successfully with zero
skips; passing compilation alone is insufficient. The accessibility UI test checks
labels, touch targets, large text, Dark Mode, and navigation; actual VoiceOver is
still a manual device check.

CI retains Linux mobile/TV builds and unit tests, shared JVM tests, Native simulator
tests, Swift playback/integration/UI tests, controlled provider fixtures, logs and
xcresult artifacts. The Apple job uses `macos-15-intel`, Xcode 16.4 and a required
iOS 18 simulator. Release linking/builds are mandatory, without failure suppression.
The timeout is 60 minutes to accommodate both additional Release framework builds.
No release publication workflow was added.

## Physical-device setup and remaining release gates

On a Mac with compatible Xcode, JDK 17 and the existing Gradle Android SDK setup:

```sh
./gradlew :shared-core:linkDebugFrameworkIosArm64
open ios-prototype/PlaybackPOC.xcodeproj
```

Select the app target, an actual iPhone, and a legitimate development team under
Signing & Capabilities. Automatic signing is enabled for devices; no team or
certificate is fabricated. Build the framework again after shared code changes.
For a Release archive, first run
`./gradlew :shared-core:linkReleaseFrameworkIosArm64`, then select a generic iOS
device and Product → Archive. An unsigned CI device build proves compilation only.
Apple Silicon simulator support is not configured by this change.

Before TestFlight: supply approved app icons, confirm bundle registration and
distribution signing, complete App Store privacy declarations and the required-
reason API dependency audit, execute the checklist below, and obtain green Phase 7
CI. `PrivacyInfo.xcprivacy` declares no tracking or collection, but its initially
empty required-reason list is **not a completed compliance audit**. CI retains the
linked app's undefined-symbol inventory for review; inspect transitive Kotlin
runtime usage as well as Swift code and add only justified reasons. See
[Apple TN3183](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest)
and [Kotlin privacy guidance](https://kotlinlang.org/docs/multiplatform/multiplatform-privacy-manifest.html).

## Manual physical-iPhone checklist

Record device/iOS version, build, actual media, observed result and diagnostics for
each item. Every physical result below is **NOT TESTED**.

| Scenario | Required observation | Result |
|---|---|---|
| Launch and catalog | Cold launch, search/details, long titles, missing artwork, empty/error/retry states | NOT TESTED |
| Episode/provider | Select repeatedly, navigate away during resolution, retry failures; no obsolete playback | NOT TESTED |
| MP4 and HLS | Playback time advances; pause, seek, end and return release media | NOT TESTED |
| Headers/cookies | Authorized controlled server observes required UA/cookies on playlists, segments and keys; unsupported requirements fail clearly | NOT TESTED |
| Audio/subtitles | Available native tracks select correctly; unsupported formats are reported accurately | NOT TESTED |
| Resume/history | Pause/exit/relaunch preserves progress; completed replay and watched/unwatched stay consistent | NOT TESTED |
| Lifecycle/interruption | Lock/background pauses; foreground requires play; calls/headphone removal flush progress; no speaker surprise | NOT TESTED |
| Network | Wi-Fi/cellular transition, offline/online, timeout and source expiry recover without retry storms | NOT TESTED |
| Accessibility | VoiceOver order/labels, largest Dynamic Type, touch targets, Dark Mode and back navigation | NOT TESTED |
| Resources | Rapid navigation, memory warnings, sustained decoding, battery/thermal and interruptions observed on hardware | NOT TESTED |

Simulator `127.0.0.1:8765` addresses are not reachable as the Mac's server from a
physical iPhone. Use original bundled MP4 or an authorized reachable HTTPS fixture
server for device HLS/provider testing; do not broaden ATS or commit credentials.
Live provider and hardware decoding support remain unproven.

Next action: run the existing consolidated CI on this branch, inspect all results
and Release artifacts, then perform signed physical-device validation using the
owner’s seven-day development signing. TestFlight distribution is deferred. Phase 7 cannot be called complete before those required checks pass.
Recommended Phase 8 scope, after these gates: a controlled internal TestFlight
pilot and evidence-driven device fixes. No Phase 8 implementation is included.
