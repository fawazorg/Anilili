# Phase 8 — real provider expansion

## Baseline and selection

Phase 7 merge `10bbc23eacc495303470e6fe5693e6900f76aa17` is present in clean,
synchronized `main`. The duplicate PR #7 run
[44260585416](https://github.com/fawazorg/Anilili/actions/runs/44260585416) passed
Android and Apple. Phase 8 uses `feature/kmp-phase8-provider-expansion`; publication and a CI run
were subsequently authorized. A separate existing Android release-publishing run
[44262103040](https://github.com/fawazorg/Anilili/actions/runs/44262103040) failed at
`Read version` (`Could not read appVersionName/appVersionCode`); it is not the
catalog/playback validation gate; its confirmed parser issue was subsequently fixed
as described below.

**Ani.pm (`anipm`) and AniChan (`anichan`)** are selected. Their existing Android
implementations use AniList IDs directly and JSON episode/source APIs. Shared
AniList search/details remain the catalog; provider availability is checked when
opening details. The app does not label every AniList result as available from a
provider. No second catalog, title matching system, or provider identity migration
is introduced.

Three agents handled read-only inventory, shared parsing/resolution and Android
adapters, and SwiftUI integration. The lead owned fixture HTTP routes, CI guard,
Xcode registration, integration review, report and Linux verification.

## Implementation and compatibility

`VERIFIED` describes an executed deterministic check, `PARTIAL` an implemented or
inspected boundary, `UNSUPPORTED` a deliberately refused capability, and `NOT
TESTED` missing runtime evidence. Fixture verification never establishes current
live service availability.

| Provider | Shared resolution | Android / TV | iOS | Live / physical |
|---|---|---|---|---|
| Ani.pm | Package availability → audio-checked bootstrap → Settlar selection/session → embed-session source | VERIFIED parser/adapters in local unit suites; existing OkHttp behavior retained; device playback NOT TESTED | VERIFIED controlled MP4/HLS simulator journey; external subtitles require explicit video-only consent | NOT TESTED |
| AniChan | Episode count/audio availability → challenge config → legitimate session POST → cookie-authenticated servers; one renewal after401 | VERIFIED parser/adapters in local unit suites; existing session/network layer retained; device playback NOT TESTED | VERIFIED controlled image-MIME HLS simulator journey; external subtitles require explicit video-only consent | NOT TESTED |

Portable code preserves language availability, ranking, leading-server subtitles,
space-only URL escaping, excluded duplicate/embed backends, subtitle language
normalization, and Ani.pm skip windows. Android keeps its existing `SkipTimes`
object and provider/episode route identities. Its adapters convert shared values to
existing Android models; Media3, TV focus, downloads, exports, authentication and
watch-history formats are unchanged. API 22 and dependency versions are unchanged.

The shared resolver owns URL/query encoding, typed HTTP/malformed/timeout/unsupported/
expired errors, one bounded operation deadline, and cancellation. Native requests
are canceled through the existing callback transport; obsolete callbacks cannot
restart a journey. AniChan resolution is serialized and obtains a fresh metadata
session per selection, with at most one renewal after401. There are no automatic
retries for unrelated HTTP/auth failures. Enabled or missing browser-challenge
configuration is rejected; no challenge is solved or bypassed.

The existing URLSession adapter retains its HTTPS-only live transport, bounded
redirects, no HTTPS downgrade, and cross-origin credential stripping. Shared
provider metadata additionally rejects final redirects to unrelated origins.
Explicit constructor-injected loopback HTTP is limited to controlled fixtures.
Media session cookies are not copied to the player. Resolved media carries the
provider User-Agent and the existing `PlaybackSource` contract. Known explicit
`expiresAtMs` is checked including resolution time; opaque/query-only upstream
expiry is not inferred or guaranteed. Expiry recovery is explicit reselection.

On iOS, the existing journey now selects Demo/Ani.pm/AniChan, sub/dub, provider
availability, details, episodes and the existing AVPlayer. Provider switching closes
obsolete tasks/player ownership. Watch history uses provider-qualified identities
and restores the saved audio selection using unchanged shared rules and native
atomic storage. Existing Demo history remains under `demo-v1`.

External provider subtitles are **UNSUPPORTED** by this AVPlayer adapter. Each
selection with external tracks requires explicit confirmation to play video
without those subtitles. The confirmation stays visible in a native bottom inset even on long episode lists.
Cancel/background/navigation clears consent. Only
external subtitle metadata is omitted after consent; audio, headers, cookies,
expiry and other capability requirements remain enforced. Embedded native HLS
tracks remain available. Arbitrary media Referer/Origin headers, strict control of
all HLS child redirects, browser execution and DRM remain **UNSUPPORTED** here.

## Inventory of existing Android routes

Inspection only: Android routes below are **PARTIAL**, current live functionality
is **NOT TESTED**, and iOS routes other than the selected pair and earlier AniDB
final-JSON boundary remain **UNSUPPORTED**. Most use AniList metadata plus provider
matching/episode inventory; own-catalog exceptions are identified explicitly.
Existing test names indicate coverage presence, not execution of live services.

| Provider | Catalog / episodes / source and formats | HTTP, browser or iOS obstacle | Existing coverage |
|---|---|---|---|
| Ani.pm | AniList ID / package JSON / Settlar HLS | Browser UA/TLS gate; external subtitles | AniPmParserTest |
| AniChan | AniList ID / episode JSON / server HLS | Explicit metadata session cookie; image-MIME TS; external VTT | AniChanParserTest |
| AniDB App | Site title matching / episode API / player JSON HLS | UA, possible challenge; only final response shared earlier | AniDbAppProviderTest, shared AniDbSourceTest |
| Zoko | MAL ID / episode probes / embed payload HLS | Referer + Origin media headers | ZokoParserTest |
| AnimePahe | Session catalog / episode API / Kwik HLS | WebView cookies/challenges and IV rewriting | Bridge/media tests |
| RareAnimes | WordPress matching / mirrors / encoded player | HTML/JS-shaped payload, guarded embeds | Parser/provider tests |
| AnimeHeaven | HTML search/details / gate / progressive MP4 | Metadata cookie; reported header-free media | Parser/provider tests |
| XFDM/Lili | Bangumi identity / HTML / MP4,HLS,embed | Chinese identity join, shipped fallback | XfdmParserTest |
| AnimeOnsen | Token bootstrap + JSON matching/episodes | Metadata session; Referer/subtitle requirements | Parser tests |
| Anikoto | AniList/MAL probes / MegaPlay HLS,embed | Host-specific HTML/Referer paths | Native/server parser tests |
| KickAssAnime | JSON matching/episodes / multi-audio HLS | Media Referer + Origin | Provider tests |
| AllAnime | API catalog / native decoding / host sources | Interactive challenge, host/crypto transforms | Provider, bundle/crypto/challenge tests |
| AnimeKai | HTML/API catalog and episodes / HLS,embed | Native decoding, Referer/Origin | Provider tests |
| Reanime | JSON catalog/episodes / Flixcloud HLS,embed | Browser bridge; playlist/segment transforms | Parser/media tests |
| AniZone | HTML catalog/episodes / HLS | Referer, external subtitles | Native parsers |
| AnimeGG | HTML episodes/mirrors / HLS,MP4,embed | Host extractors/Referer | Provider/native parsers |
| AniNeko | HTML per-audio mirrors / HLS,embed | Host embeds/external subtitles | Native parsers |
| 2Dhive | MAL-keyed Astro properties / MegaPlay | HTML/mirror Referer | Native parsers |
| AnimeDekho | WordPress seasons/mirrors / embed | External player execution | Parser tests |
| ToonHub | HTML seasons/mirrors / embed | Guarded embed navigation/headers | Parser/provider/catalog tests |
| UniqueStream | JSON seasons/episodes / HLS | Android key interception/synthesis | Parser/key-source tests |
| AnimeKhor | Country-locked WordPress / mirrors | Encoded iframe/external player | Parser tests |
| Kartoons | JSON catalog/seasons/episodes / signed HLS | Account-token pool, short-lived IDs | Parser/provider/rotation tests |
| AnimeAV1 | Svelte JSON/MAL-confirmed catalog / embeds | VOE host decoding; other media require Referer | Parser tests |
| Rift | Firebase bootstrap/JSON catalog/episodes/source | Context/install/session gateway credentials | RiftParserTest |
| Hanime | Own catalog/API / HLS | Context/cache/browser credentials | Catalog/media/parser tests |
| HentaiHaven | Own sitemap/title/episode HTML / HLS | Challenges and external CDN | Parser tests |
| HStream | Own sitemap/details / CSRF session / DASH,MP4 | DASH unavailable in current AVPlayer | Parser tests |
| One Pace | Own React-flight single-title timeline / MP4 | Non-AniList identity/order; larger extraction | OnePaceParserTest |
| Miruro native: bee,sun,pewe,hop,ally,kiwi,moo,bonk,knob | Shared Miruro JSON catalog/play / HLS | Dynamic configuration, variants and headers | MiruroCatalogTest/native media tests |
| Miruro embeds: nun,bun,cog,twin,telli | Parent-derived episode IDs / iframe | Host/browser extraction; telli retired/hidden | Embed/parser tests |

One Pace was deferred because it requires a separate non-AniList identity/catalog
slice. AnimeAV1 was deferred because its host decoding and Referer requirements
exceed this bounded migration. No new provider or access-control workaround was
introduced.

## Deterministic fixtures and evidence

The existing loopback server now exposes `/provider/expanded/anipm` and
`/provider/expanded/anichan`, including raw AniList-shaped `/catalog` responses.
All catalog titles, session selections/tokens/cookies and media are original test
data. Nothing is copied from private provider accounts or expiring source URLs.
Logs omit request bodies, query strings and header values.

- Ani.pm fixtures validate encoded selection/token round trips, independent sub/dub
  availability, MP4 episode1 and HLS episode2, and external-track consent.
- AniChan fixtures require the provider UA on metadata, a legitimate synthetic
  session POST and cookie on server resolution. Relative HLS playlists request
  original MPEG-TS bytes with `.ts.png` paths and `image/png` MIME. Only native
  playback progression can establish AVPlayer compatibility with that delivery.
- Shared tests cover malformed/empty responses, HTTP401/403/404/429/5xx, session
  renewal limits, active challenge refusal, redirects, cancellation/deadline,
  explicit expiry, identity/audio mismatch, mapping and capability preservation.
- Five new Swift integration tests require catalog/details/episodes, real native
  provider HTTP chains, >1 second playback progression, back cleanup/history,
  cancellation/late callbacks, explicit subtitle consent and persisted dub resume.

| Validation | Status | Execution evidence |
|---|---|---|
| Phase 7 baseline Android and Apple | PASS | Duplicate run44260585416 success, before branch creation. |
| Separate Android release publication | FAIL (historical); parser fix locally PASS | CRLF in app/build.gradle.kts broke the anchored version-name expression. The reader now strips CR before parsing; LF/CRLF and invalid-value regression tests pass. Publication was not rerun. |
| Shared JVM tests | PASS | 89 tests, zero failures/errors/skips; includes 22 new provider cases. |
| Android mobile/TV unit tests and debug builds | PASS | Each flavor: 2,583 total, 2,578 passed, five existing optional live probes skipped. Two new adapter tests passed per flavor. Both debug builds succeeded. |
| Python fixture and CI tests | PASS | 20 tests, including two release-version regressions; HTTP session cookie and encoded query behavior observed at server. |
| Phase 8 Native/Swift build and simulator tests | FAIL (first hosted run) | Run44271291773: Android and shared Native steps passed; all61 Swift unit tests passed, including all five expanded-provider tests with observed playback >1second. Two existing UI journeys passed; the accessibility UI test overscrolled Pause above the visible area, then continued upward. Short directional drags now follow its frame; hosted rerun pending. |
| Phase 8 unsigned Release builds | NOT TESTED | Skipped after the UI failure; remain mandatory in the manual rerun. |
| Live providers, physical Android/TV/iPhone | NOT TESTED | No live calls, device playback or Apple signing executed. |

Local command (existing JDK17 and Android SDK):

```sh
./gradlew :shared-core:jvmTest :app:testMobileDebugUnitTest :app:testTvDebugUnitTest \
  :app:assembleMobileDebug :app:assembleTvDebug -x :app:syncParityCorpus \
  --offline --console=plain --no-configuration-cache
./gradlew :shared-core:jvmTest --offline --console=plain
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s ios-prototype/ci -p 'test_*.py'
```

`syncParityCorpus` was excluded to preserve generated resources from sibling
checkouts. No data was deleted. A nullable assertion type mismatch in the two
last-added test cases was corrected before the final 89-test pass. Static workflow
shell/Python syntax, plist/scheme parsing, all 73 Xcode object references, and
whitespace checks passed. Existing Android deprecation warnings and prior
coroutines-test opt-in warnings remain. Linux disables Apple targets as expected.

Files changed: shared `ExpandedProviderParsers.kt`, `ExpandedProviderClient.kt`,
`ExpandedProviderTest.kt`; Android `AniPmProvider.kt`, `AniChanProvider.kt`,
`SharedProviderAdapters.kt`, `SharedProviderAdapterTest.kt`; iOS `JourneyModel.swift`,
`JourneyView.swift`, `WatchHistoryModel.swift`, `PlaybackPOCApp.swift`, new
`ExpandedProviderJourneyTests.swift`; Xcode project registration;
`ci/serve_fixtures.py`, `test_expanded_providers.py`, `verify_results.py`,
`test_verify_results.py`; this report. No Gradle/dependency upgrades or new workflow
jobs are necessary: common tests and new registered Swift tests use existing CI.

Next action: run consolidated CI on the published branch and inspect actual
provider progression and release artifacts. Phase 8 is not
complete until required hosted checks pass. Recommended Phase 9 scope, only after
that gate: signed physical-device/live-provider validation and measured fixes for
unsupported subtitle/delivery requirements; no Phase 9 code is included.

## Recovery and temporary trigger policy

User requested manual testing only for now. Both `kmp-ci.yml` and `release.yml` now
use only `workflow_dispatch`; PR and main-push automatic triggers are paused.
All test/build jobs and failure guards remain enabled. CI is dispatched explicitly
after pushing fixes; automatic release publication is not requested. The release
reader fix does not change app versions, signing or the existing Gradle file's
CRLF format. New `ci/test_release_version.py` executes the actual workflow step.

In failed run44271291773, controlled AniChan image-MIME HLS progressed1.0003s,
Ani.pm MP4 progressed1.0002s, and both provider episode2 HLS consent paths
progressed beyond1s. These are **VERIFIED simulator fixture results**, not live
provider or physical-device evidence. The accessibility target frame moved from
y637.5 to y-32.5, then y-56 while the old helper kept swiping upward; the fix
retains the same hittability, label and44-point touch-target assertions.
