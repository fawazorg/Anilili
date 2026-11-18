# Phase 9 — offline readiness

## Baseline and scope

**PASS:** Phase 8 merge `eb1d8cbadf96fee8e49af63a22bf988cfd5caf51` was present in
clean local `main`, matching `origin/main`. Its tested head
`dd88d8b3beda6999a584008f135560f65956ebec` passed Android/TV and Apple in
[run44279336550](https://github.com/fawazorg/Anilili/actions/runs/44279336550).
Work is isolated on `feature/kmp-phase9-offline`; publication and a manual CI run
were subsequently authorized. No PR or merge was requested.

Two agents implemented the shared domain and native iOS engine/store/tests. The
lead audited Android boundaries and integrated UI, offline playback/history,
fixture HTTP behavior, privacy declaration, Xcode registration, CI guards and QA.

Android already has a Media3 DownloadManager/DownloadIndex and SimpleCache, custom
provider playlist/key data sources, per-request headers, stop-reason pause/resume,
failed-request retry, subtitle jobs and size estimates/StatFs checks. Export runs
through the existing export pipeline/worker and selected Android storage locations.
These platform-specific systems and their persistence formats remain unchanged.
The existing shared DownloadStallTracker extraction is also unchanged. The new KMP
queue is consumed by iOS; Android's queue is deliberately not replaced merely for
architectural symmetry.

## Implementation

- **Shared domain:** versioned JSON snapshot, provider/anime/episode identity and
  episode number, FIFO ordering, duplicate prevention, byte progress/unknown length,
  typed failures, opaque local handles and explicit state transitions. Queue flow
  is QUEUED → DOWNLOADING → COMPLETED, with PAUSED/FAILED/CANCELLED recovery intents.
  Global generations and ordered updates reject obsolete callbacks even after
  deletion/re-enqueue. Native adapters implement atomic compare-and-set. Unknown or
  corrupt metadata is preserved and reported, never silently reset.
- **MP4:** native foreground URLSessionDownloadTask, sandbox file move, HTTP200/206
  handling, byte progress, disk reserve checks, supported in-process resume data,
  cancellation and safe retry. It pauses on background entry. Resume blobs and
  source credentials remain in memory; after process restart, interrupted MP4
  metadata recovers PAUSED and needs fresh source resolution, potentially from byte
  zero. No background MP4 continuation is promised.
- **HLS:** native AVAssetDownloadURLSession with AVAssetDownloadConfiguration,
  finite/unprotected VOD validation, time-range progress, suspend/resume, stable
  background-session identifier, task reattachment and app-delegate event handoff.
  Pending validation/persistence finishes before the background completion handler.
  Native packages remain at Apple's location. Completion requires native task
  success, local playability and `assetCache.isPlayableOffline`; streaming cache or
  partial segments alone never qualify. iOS18's willDownloadTo and the iOS17
  completion-location callback are both handled.
- **Storage:** iOS-only `Application Support/AnililiOffline/downloads.json`, excluded
  from backup, reuses the existing locked atomic-file adapter. MP4 filenames are
  generated UUIDs. MP4 SHA-256 receipts detect same-size corruption; hashing for user
  playback and transfer finalization occurs off the main actor. HLS references are
  canonical sandbox-relative pointers bound to their opaque key by an integrity
  digest. Cleanup accepts only owned handles; unrelated files are never scanned or
  deleted. Damaged media is cleaned before its metadata handle is invalidated;
  failed cleanup preserves the handle so deletion can be retried.
- **Source policy:** HTTPS live sources; loopback HTTP requires explicit fixture
  configuration. Expiration, headers, cookie domain/path/secure/expiry and existing
  Apple capability rules are checked. MP4 redirects are limited to the same origin.
  Partial transfers resume only when the complete in-memory source profile still
  matches; changed credentials or an unverifiable restored HLS profile require a
  fresh native transfer. No DRM, browser challenge, or access-control workaround is
  introduced. External subtitles retain Phase8's explicit video-only consent.
- **Native UI/playback:** provider episode context actions offer Download. The
  Downloads tab reports queue state, progress, completed-media size, pause/resume,
  cancel, retry, delete and local playback. A fresh-source requirement is explained
  rather than presenting a silent no-op. Completed media uses the existing AVPlayer
  and shared watch-history rules. Episode selection prefers validated local media
  and falls back to ordinary provider resolution when it is unavailable. The
  Downloads tab itself works without catalog access. Validation tasks are canceled
  or generation-checked on navigation, deletion and backgrounding.

Disk-capacity checks declare `NSPrivacyAccessedAPICategoryDiskSpace` reason
`E174.1` (sufficient space to write files). No tracking or analytics was introduced;
this does not complete the pre-existing transitive-runtime privacy audit. See
[Apple required-reason guidance](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
Apple's [HLS sample](https://developer.apple.com/documentation/avfoundation/using-avfoundation-to-play-and-persist-http-live-streams)
allows simulator testing on iOS15+, but it is not evidence that this implementation
has passed. Native background behavior follows the
[asset-download session API](https://developer.apple.com/documentation/avfoundation/avassetdownloadurlsession).

## Validation

| Check | Result | Evidence |
|---|---|---|
| Shared JVM tests | PASS | 115 tests; zero failures/errors/skips, including 26 new download-domain cases. |
| Android mobile unit tests | PASS | 2,583 total; 2,578 passed, five existing optional live probes skipped. |
| Android TV unit tests | PASS | Same counts; no failures/errors. Skipped probes are NOT TESTED. |
| Mobile/TV debug builds | PASS | Both assemble tasks succeeded; Android production source/UI/storage untouched. |
| Python fixture and CI guards | PASS | 29 tests, including actual scoped cookie/UA enforcement, Range validators, truncation and per-test origin shutdown. |
| Static CI/project validation | PASS | Manual-only triggers, workflow shell/Python syntax, plist/scheme parsing, 83 Xcode object references and whitespace checks. |
| Native common tests / Swift compilation | PASS on first hosted run | 115 Native tests passed; Swift test binaries compiled. |
| Swift simulator tests | FAIL on latest hosted run | Run44339552581 executed73 unit/integration tests and3 UI tests. The sole failing test was native HLS package registration (two assertions). The correction adds one regression case, requiring77 tests on rerun. |
| Real MP4/HLS native downloads and offline playback | PARTIAL | MP4 download, origin-disabled playback, persistent resume and local-to-online fallback passed in run44339552581. HLS failed package-location validation before offline playback. Physical devices remain NOT TESTED. |
| Unsigned Release simulator/device builds | NOT TESTED | Existing mandatory CI steps preserved. |
| Hosted Phase9 workflow | FAIL (historical); recovery rerun pending | Run44304079169: Android passed, Apple failed in offline tests. Verify the recovery commit before claiming success. |
| Physical Android/TV/iPhone, live providers and background relaunch | NOT TESTED | Build/test success on Linux is not runtime or hardware evidence. |

Local validation used JDK17 and the existing SDK:

```sh
./gradlew :shared-core:jvmTest :app:testMobileDebugUnitTest :app:testTvDebugUnitTest \
  :app:assembleMobileDebug :app:assembleTvDebug -x :app:syncParityCorpus \
  --offline --console=plain --no-configuration-cache
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s ios-prototype/ci -p 'test_*.py'
```

`syncParityCorpus` was excluded to preserve generated resources from sibling
checkouts; no generated or user data was deleted. Expected Apple targets are
disabled on Linux. Existing Kotlin/Android deprecation warnings remain.

The eleven `OfflineDownloadTests` require real MP4 transfer, real HLS package download
and origin-disabled playback, pause/resume/cancel, low-space/HTTP failure,
truncation/invalid media, same-size corruption, safe cleanup, metadata preservation,
expiration and changed-cookie rejection. Two `OfflineJourneyTests` require MP4
playback after its origin returns503, persisted watch-history resume after player
recreation, no provider resolution for local selection, and online fallback after
local deletion. Each playback test requires actual media-clock progression.

The controlled server supplies original progressive/HLS assets, slow ranged
responses, interrupted bodies and invalid media. `/provider/offline/isolated/<id>`
can be disabled independently after download; subsequent remote requests return503
while the required test attempts local playback. No live provider is required in CI.
No test is skipped to hide missing HLS/platform support.

## CI and remaining device gates

Automatic workflows remain paused at the owner's request. `kmp-ci.yml` and
`release.yml` remain manual-only; no repository settings or automatic triggers were
changed. All Phase1–8 checks, Native tests, unsigned Release builds and failure
artifacts remain. The result guard also requires both offline suites and every
discovered Swift test to pass with zero skips.

Required device checks: MP4 suspension/resume, HLS background completion/system
relaunch, force-quit/restart behavior, package eviction, provider UA/cookie delivery
on HLS child requests, storage pressure, interruption/network switching, hardware
playback, battery/thermal use, and downloaded audio/subtitle selections. All remain
**NOT TESTED**. Only downloaded native media selections are available offline;
external subtitle files and protected/live HLS are unsupported. Apple controls
background scheduling; user force-quit and expired provider URLs cannot be promised
continuous downloading. HLS system eviction is detected when local playback is
requested. HLS uses native cache/playability checks rather than a full package
checksum; later decode errors require deletion and a fresh download. Completed-media
size excludes Apple temporary/in-progress storage.

Files added: shared `downloads/DownloadRepository.kt` and its common test; iOS
`OfflineDownloadStore.swift`, `OfflineDownloadEngine.swift`, `DownloadsView.swift`,
`OfflineDownloadTests.swift`, `OfflineJourneyTests.swift`; CI
`test_offline_fixtures.py`; this report. Modified: `JourneyModel.swift`,
`JourneyView.swift`, `PlaybackPOCApp.swift`, `PrivacyInfo.xcprivacy`, Xcode project,
`ci/serve_fixtures.py`, `verify_results.py`, `test_verify_results.py`.
No dependency, Android minimum SDK, package identity or Android data format changed.

Next action: manually run consolidated CI on the published branch;
inspect actual MP4/HLS offline progression and Release results before claiming
Phase9 complete. Recommended Phase10 scope only after that gate: physical-device
background/recovery and storage-pressure validation with measured fixes. No Phase10
implementation is included.


## First hosted-run recovery

[Run44304079169](https://github.com/fawazorg/Anilili/actions/runs/44304079169)
confirmed successful Android builds and115 shared Native tests. MP4 origins returned
HTTP200, while completion failed; inspection found storage comparing directory URL
objects whose directory/trailing-slash representations can differ. Roots now have
an explicit directory representation and containment checks compare canonical
parent paths, preserving UUID and symlink restrictions. A focused file-move test
covers both directory hints.

HLS failed with SecTaskLoadEntitlements error22, background-service XPC4099/4097,
and an unavailable remote AVAssetDownloadTask session. Tests had been explicitly
unsigned. CI now builds the simulator test host with an ad-hoc signature and a
simulator-only Debug application identity, verifies codesign and its entitlements,
then runs tests without rebuilding. No Apple certificate/team/profile is invented;
device signing and unsigned Release builds are unchanged. Simulator entitlement
handling differs from physical devices, as explained by
[Apple DTS](https://developer.apple.com/forums/thread/791736).

Offline test waits now stop on a failed transfer and assert COMPLETED with the
safe engine error, rather than cascading through later playback assertions. No
playback assertion, suite, required check or skip guard was removed. Simulator
re-execution is pending; these fixes are not a claim that offline playback passed.
New recovery files: App/Simulator.entitlements, ci/verify_simulator_signing.py and
ci/test_simulator_signing.py. Both workflows remain manual-only.


## Second hosted-run recovery

[Run44312895790](https://github.com/fawazorg/Anilili/actions/runs/44312895790)
stopped before simulator tests: codesign verification succeeded, but the identity
guard rejected an empty signature entitlement dictionary. The build log shows the
correct application identifier and debug claim in PlaybackPOC.app-Simulated.xcent,
while PlaybackPOC.app.xcent was empty. CI now explicitly applies the generated,
expanded simulator claims to the existing ad-hoc app signature, verifies the
signature again, extracts the signed claims and runs the same strict identity
guard. This is limited to the simulator test product; device/Release signing and
all test assertions remain unchanged.

The independent Android job failed resolving kotlin-test2.1.21 and
kotlinx-coroutines-test1.8.1 before tests executed. Their existing Maven Central
POMs returned HTTP200 when checked. The Linux Gradle command now refreshes dependency
metadata rather than reusing missing-artifact results. No dependency or repository
version was changed. The26 local Python tests and workflow syntax checks pass;
both hosted jobs still need a successful rerun. Automatic triggers remain paused.


## Third hosted-run recovery

[Run44320334266](https://github.com/fawazorg/Anilili/actions/runs/44320334266)
passed Android. The simulator build and ad-hoc signing also succeeded, but test
launch was stopped by a plist parse error. The retained entitlement artifact
contained the correct application identifier/debug claims in codesign's default
human-readable DER representation (`[Dict]`, `[Key]`, `[Value]`), not XML. The export
command now explicitly requests `--xml`, matching
[Apple TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).
The strict identity and signature guards remain; tests and unsigned Release steps
remain required. A new hosted run is needed to execute them.


## Fourth hosted-run recovery

[Run44329265802](https://github.com/fawazorg/Anilili/actions/runs/44329265802)
passed Android, but the simulator crash artifact reports SIGKILL with termination
namespace CODESIGNING and indicator `Taskgated Invalid Signature`. The manual
re-signing introduced during the second recovery copied iOS simulator claims into
the macOS host signature and prevented application launch. No simulator playback
or Release validation passed in this run.

The manual re-signing is removed. CI retains Xcode's ad-hoc signature, verifies it,
and checks the application identifier and debug claim in the executable's actual
`__TEXT,__entitlements` section. A bounds-checked Intel Mach-O reader has three
regression tests for valid identity, malformed sections and incorrect identity.
A simulator install/launch smoke check now precedes the unchanged XCTest run.
All 29 local Python tests pass; workflow shell syntax and manual-only triggers
also pass inspection. All required simulator suites, playback assertions and
Release builds remain mandatory. Hosted validation of this correction is pending;
physical-device signing and playback remain NOT TESTED.


## Fifth hosted-run recovery

[Run44339552581](https://github.com/fawazorg/Anilili/actions/runs/44339552581)
passed Android, shared iOS tests, simulator signature/identity/launch checks,
MP4 download and offline-resume journeys, and all three UI tests. The remaining
failure is `testHLSNativePackagePlaysAfterItsOriginIsDisabled`: its download state
became FAILED with `The HLS package location was invalid`, followed by the expected
missing-local-URL assertion. Release steps were consequently not executed.

The receipt validator imposed an undocumented Library-only location restriction.
Apple's delegate contract supplies the system-selected package URL and requires
keeping it there; it does not guarantee that directory. Receipt registration now
accepts native `.movpkg` locations within this app's canonical sandbox, retaining
symlink rejection, package suffix checks, UUID keys, bound relative receipts and
outside-sandbox rejection. Packages are never moved. A new Swift regression checks
Library/Documents locations, pre-creation registration, repository recreation,
receipt-based deletion and unsafe inputs. The logs do not expose the rejected
package path; a successful hosted HLS rerun is still required to confirm recovery.

All29 local Python tests and whitespace checks pass. The new Swift regression and
all77 required Swift/UI tests remain pending Apple execution. Automatic workflows
remain manual-only; no required tests or Release checks were removed.


## Sixth hosted-run recovery and CI timing

Run44363804551 passed Android, Native shared tests and all existing MP4/UI journeys,
but HLS registration still failed. The Library-only correction was insufficient;
the prior generic catch concealed which validation or receipt-write operation
failed. Registration now reports a fixed privacy-safe category and resolves the
callback's absolute URL before canonicalization; its regression also covers a
home-relative file URL. The exact remaining hosted rejection is not yet known.

The Apple framework step took18m12s and the complete failed job about36minutes.
Logs show `cache-read-only: true`, no Gradle cache restored, and repeated Native
toolchain downloads. Manual branch runs now write Gradle caches, persist ~/.konan
with OS/architecture/Xcode/dependency-version keys before Swift tests, and stop
forcing Linux dependency metadata refresh on every invocation. A focused HLS
preflight fails before the full Swift suite on this regression; success still
requires the entire77-test suite, zero-skipped guard and both Release builds.
Automatic triggers remain paused. All29 local Python tests, workflow shell syntax
and whitespace checks pass. Timing improvements and HLS recovery require another
hosted run; no time-saving estimate is claimed as measured.
