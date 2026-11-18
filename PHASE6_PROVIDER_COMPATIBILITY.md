# Phase 6 provider and playback compatibility

Baseline: merged Phase 5 `b65ee3276169b677ceb9c629692381b4cee5abeb`; its Android and Apple CI jobs passed. This phase's live-provider and physical-device tests have **NOT TESTED** status. Repository comments describe earlier observations, not fresh network evidence.

`VERIFIED` means the stated deterministic check actually executed; `PARTIAL` means a smaller boundary is implemented or inspected; `UNSUPPORTED` means no adapter/capability exists in this iOS slice; `NOT TESTED` means runtime evidence is absent. Android/TV resolver presence below is **PARTIAL** static evidence, not a claim that every live upstream currently works. iOS inventory status concerns this implementation, not all theoretical AVFoundation capabilities.

## Selected boundary

**AniDB App** is selected: `AniDbAppProvider.sources` already fetches `episode/<server-path>/iframe` from the player API and reads a JSON `link` to direct HLS. This request needs neither WebView execution nor Android-specific playlist/key rewriting. The shared extraction preserves Android's title matching, episode offsets, server selection, request headers and final Media3 playback. iOS consumes the same final response parser through a cancellable HTTP adapter; this does **not** migrate the entire AniDB catalog or prove that a freshly matched live title resolves.

No second provider is migrated. One Pace's header-free MP4 delivery is a useful future candidate, but its React-flight catalogue and non-AniList identities would expand this slice. KAA/Zoko's required Referer/Origin, Pahe's browser flow, UniqueStream's key adapter and Flixcloud's response transformations are deliberately not approximated.

## Inventory of registered provider paths

Evidence: `data/ProviderCatalog.kt`, `remote/AnivexaClient.kt` dispatch/constructors, `remote/PipeClient.kt`, `remote/MiruroCatalog.kt`, and each named `remote/*Provider.kt`. All native HTTP implementations currently use Android-side OkHttp/JVM facilities; browser paths additionally use Android bridges. Every row is Android/TV **PARTIAL** until its listed deterministic regression or live path is exercised in this phase. `H/P/E/D` below mean HLS, progressive, embed and DASH.

| Provider | Existing Android mechanism / media | Request or platform assumptions | iOS slice |
|---|---|---|---|
| AniDB App (`anidbapp`) | Website/catalog identity → player JSON → H | API User-Agent; media described as header-free; title match remains Android | PARTIAL: selected final JSON-link boundary |
| Ani.pm (`anipm`) | AniList-keyed JSON packages/session → H | Browser-like User-Agent; session/Settlar JSON | UNSUPPORTED adapter |
| AniChan (`anichan`) | AniList-keyed JSON episodes/session → H | Session/token and HTTP headers; no browser required by resolver | UNSUPPORTED adapter |
| Zoko (`zoko`) | MAL-keyed embed HTML payload → H | Referer/Origin pair on media; HTML/JSON extraction | UNSUPPORTED request requirements |
| AnimePahe (`animepahe`) | Session catalogue → browser-assisted Kwik → H | Android WebView/cookies; per-segment IV rewriting | UNSUPPORTED browser/media adapter |
| RareAnimes (`rareanimes`) | WordPress → redirects → encoded player response | HTML/JS-shaped payload parsing; host/cookie policies, embed fallbacks | UNSUPPORTED adapter |
| AnimeHeaven (`animeheaven`) | Search/title/gate HTML → P | Gate key cookie; returned CDN media described as header-free | UNSUPPORTED adapter |
| Lili/Xfdm (`xfdm`) | Bangumi-keyed HTML catalogue → P/E | Bangumi lookup, shipped-source fallback, embed handling | UNSUPPORTED adapter |
| AnimeOnsen (`animeonsen`) | JSON API/bootstrap → sources/tracks | OAuth-style bootstrap token, cached HTTP session; multilingual subtitles | UNSUPPORTED adapter |
| Anikoto (`anikoto`) | Site/identity and MegaPlay response → H/E | HTML/embed resolution and Referer; optional fallback sources | UNSUPPORTED adapter |
| KickAssAnime (`kaa`) | JSON API → multi-audio H | Media Referer **and Origin**; server-specific mapping | UNSUPPORTED request requirements |
| AllAnime (`allanime`) | API plus native decoding and interactive challenge path | Optional Android challenge/browser bridge; provider payload transforms | UNSUPPORTED adapter |
| AnimeKai (`animekai`) | Site/API decoding → H/E | Native provider decoding, Referer and embed fallbacks | UNSUPPORTED adapter |
| Reanime (`reanime`) | Catalog plus browser/Flixcloud resolution → H/E | Android browser bridge; playlist and wrapped-segment transforms | UNSUPPORTED browser/media adapter |
| AniZone (`anizone`) | HTML catalogue/episode source → H | Referer and external subtitle extraction | UNSUPPORTED adapter |
| AnimeGG (`animegg`) | HTML episode mirrors → H/P/E | Third-party embed extraction; per-host Referer | UNSUPPORTED adapter |
| AniNeko (`anineko`) | HTML episode mirrors → H/E | Per-audio embed HTML and subtitle URL handling | UNSUPPORTED adapter |
| 2Dhive (`2dhive`) | MAL-keyed page properties/MegaPlay → H/E | Astro/HTML metadata, per-mirror requests and Referer | UNSUPPORTED adapter |
| AnimeDekho (`animedekho`) | WordPress and trdekho mirror endpoints → E | Hosts execute their own player behavior; controlled browser surface | UNSUPPORTED embed adapter |
| ToonHub4u (`toonhub`) | HTML season/mirror catalogue → E | ToonStream/mirror headers and guarded embed navigation | UNSUPPORTED embed adapter |
| UniqueStream (`uniquestream`) | JSON seasons/episodes/media → H | Android key interception/synthesis; locales and subtitles | UNSUPPORTED key adapter |
| AnimeKhor (`animekhor`) | WordPress/select mirrors → E | Country-locked catalogue; encoded iframe data and external players | UNSUPPORTED embed adapter |
| Kartoons (`kartoons`) | JSON catalogue/token surface → signed H | Token pool/session and short-lived media; legitimate token lifecycle required | UNSUPPORTED adapter |
| AnimeAV1 (`animeav1`) | HTML/YourUpload mirror → P/E | Spanish catalogue; Referer and provider-specific host handling | UNSUPPORTED adapter |
| AnimeRift (`rift`) | Firebase/bootstrap/mobile JSON → H/P/E | Android Context/bootstrap credentials and host APIs | UNSUPPORTED adapter |
| Hanime (`hanime`) | Native catalogue plus browser-issued source credentials → H | Android WebView/session; adult catalogue restrictions | UNSUPPORTED adapter |
| Hentai Haven (`hentaihaven`) | Next.js/HTML manifest extraction → H | HTTP page headers; direct-media behavior is source-specific | UNSUPPORTED adapter |
| HStream (`hstream`) | HTML CSRF/session → JSON → D | Session cookie + CSRF; header-free DASH mirrors; DASH not AVPlayer HLS | UNSUPPORTED format/adapter |
| One Pace (`onepace`) | React-flight watch catalogue → Pixeldrain P | Reserved negative title ID; media described as header-free; burnt-in captions | UNSUPPORTED catalogue adapter |
| Miruro `bee`, `sun`, `pewe`, `hop`, `ally`, `kiwi`, `moo`, `bonk`, `knob` | Shared Miruro config/catalog/play JSON → native H | Individual source headers, soft/hard-sub variants and expiring play cache | UNSUPPORTED Miruro adapter |
| Miruro `nun`, `bun`, `cog`, `telli` | Shared Miruro config/catalog/play JSON → E | Iframe execution; aliases describe parent providers, not equivalent source access | UNSUPPORTED embed adapter |
| Miruro `twin` | Same JSON → E with narrow native extraction when declared | Embed resolver/Referer; direct H can only be used after successful extraction | UNSUPPORTED adapter |
| Retired `anibd`, `senshi` | Retained explanatory comments, absent active fan-out | Earlier upstream outages; no new recovery claim | UNSUPPORTED / not migrated |

BabaStream is an embed-resolution helper (`BabaStreamClient.kt`: page-session config plus platform crypto/API work), not a separate catalogue provider; its iOS adapter is UNSUPPORTED. The grouped Miruro rows enumerate every name in `miruroOrder`; the native rows enumerate `anivexaProviders` plus title-bound One Pace. API clients such as AniList, AniZip, Jikan, TMDB and OpenSubtitles supply metadata rather than independent video-provider playback and are not represented as streaming providers.

## Media and request matrix

| Capability | Android/TV | iOS | Evidence and boundary |
|---|---|---|---|
| Selected AniDB JSON `link` → shared media contract | PARTIAL | PARTIAL | Shared implementation supplied; this report does not assert live endpoint success. |
| Original MP4 and relative HLS manifests | NOT TESTED in Phase 6 Media3 runtime | NOT TESTED in Phase 6 AVPlayer runtime | Existing original assets retained; new compatibility tests must observe time advancement. Prior-phase success is not current provider proof. |
| HTTP status, redirects, timeout fixture server | VERIFIED server contract | NOT TESTED native adapter | Seven Python fixture-server tests executed on Linux, including same-origin chains, distinct-origin redirect target, failures and client deadline. |
| User-Agent plus synthetic cookie on HLS master/variant/segment/key | VERIFIED server enforcement; Media3 propagation NOT TESTED | NOT TESTED AVPlayer propagation | Each resource rejects missing UA or cookie. Native tests must prove actual authorized requests, not just header model presence. |
| Standard original AES-128 HLS | VERIFIED Linux decode | NOT TESTED AVPlayer | Fixed public synthetic fixture key and explicit IV; no upstream key or DRM bypass. |
| Referer/Origin/Authorization media headers | Existing Android per-source support; NOT TESTED new runtime | UNSUPPORTED here | No undocumented AVURLAsset arbitrary-header option; requirements must fail explicitly. |
| Cookies across unrelated hosts/redirects | NOT TESTED | NOT TESTED | No blanket credential-forwarding promise. Domain/path/secure/expiry scope must be respected. |
| Strict SAME_ORIGIN/DENY policy for all AVPlayer child requests | NOT TESTED | UNSUPPORTED here | AVPlayer cannot publicly expose every HLS request/redirect; metadata resolver policies are separate. |
| Audio/WebVTT selection | Existing original master | NOT TESTED new compatibility path | Original English/French tone and caption tracks retained; tests must select tracks and observe continued playback. |
| Expiry/retry/cancellation/history interaction | PARTIAL | PARTIAL | Deterministic shared/native tests supplied; actual executed results belong in final validation below. |

## Controlled fixture protocol

Run `python3 ios-prototype/ci/serve_fixtures.py`; it binds only `127.0.0.1:8765`.

- `/provider/anidb/hls`, `/mp4`, `/relative`, `/gated` return the selected response shape (`link`, optional format/headers/cookies). `/expired`, `/missing`, `/malformed`, `/unsupported`, `/unsupported-headers`, `/unsupported-policy` exercise rejection.
- `/provider/redirect/2` → `/1` → valid response; `/provider/redirect-cross-origin` points to the same loopback server under the distinct `localhost` origin, for credential/policy rejection tests.
- `/provider/status/{401,403,404,429,500,503}`, `/provider/flaky` (503 once), and `/provider/timeout?seconds=2` are deterministic failure/retry/deadline probes.
- `/provider/gated/hls/master.m3u8` contains a relative variant, relative TS segments and `key.bin`. Every request requires original fixture UA `AnililiFixture/1.0` and synthetic cookie `fixture_session=authorized`, scoped to `/provider/gated`.
- `/provider/requests` reports only paths and matched/not-matched booleans; it never returns raw Cookie/Authorization/header values. `?clear=1` clears audit state for serial tests. HTTP request logs also omit query strings and header values.

All media is generated from the existing FFmpeg test pattern/sine fixture. `python3 ios-prototype/Fixtures/provider/generate.py` regenerates AES-HLS using fixed public test-only bytes and an explicit IV. Nothing was fetched from a real provider; no private token, provider cookie or expiring media URL is stored.

## Validation and next gate

**VERIFIED:** complete Linux FFmpeg decode of the original AES-128 HLS master, plus seven Python fixture-server tests on Linux (two retained range/MIME tests and five provider contract tests), including per-resource cookie/UA enforcement, Range delivery, redirect responses, HTTP failures, expiry/malformed responses and client timeout. These establish the server harness, not native playback compatibility.

**NOT TESTED:** live AniDB resolution/catalog matching, physical iPhone/iPad, Media3 device playback, codecs/hardware decoding, external subtitle styling, DRM, background interruptions, battery/thermal behavior and network transitions. Actual macOS/Kotlin/Native/Swift results are pending execution. There is no evidence here that an alternative engine is necessary; first run controlled native tests, then test authorized real sources on physical devices. Do not begin Phase 7 based solely on mocked resolution or successful compilation.

## Final local execution evidence

| Check | Status | Evidence |
|---|---|---|
| Shared JVM provider/domain tests | VERIFIED | 67 tests, zero failures/errors/skips, including all prior shared history/catalog/episode tests and thirteen provider tests. |
| Android mobile / TV unit suites | VERIFIED | 2,581 tests reported per flavor, zero failures/errors, five existing optional live probes skipped (2,576 executed per flavor). New shared AniDB adapter tests pass. |
| Android mobile / TV debug builds | VERIFIED | Both assemble tasks completed successfully. This is build evidence, not device playback evidence. |
| Python fixture and CI guards | VERIFIED | Twelve tests pass: seven HTTP/range/provider/log-redaction cases and five required-suite/result guards. |
| Original encrypted HLS decode | VERIFIED | Full local FFmpeg decode of the generated AES-128 HLS master completed without errors. This is not AVPlayer evidence. |
| Kotlin/Native and Swift build/runtime | NOT TESTED | Existing unified macos-15-intel workflow is prepared; all 45 Swift cases are required, including nine new provider cases. No hosted run was triggered. |
| Live AniDB / physical Android, TV, iPhone | NOT TESTED | No live provider calls, credential use, or device playback performed. |

The selected iOS path resolves a supplied known server endpoint from the existing manual playback screen. It does not migrate provider catalog/title matching or assign live-provider watch-history identities. The Phase 5 connected demo/history path and its tests remain intact. Refresh after expiry is an explicit user action, not an automatic retry loop; no automatic midstream provider re-authentication is claimed. Android continues using its existing HTTP/retry/cache layer while sharing source parsing and validation. Its AniDB adapter explicitly rejects newly declared cookie/strict-redirect/capability requirements instead of ignoring them.

The resolver allows at most three requests within one operation deadline. Authentication/not-found failures are not retried. Retry-After values exceeding the bounded delay, date-formatted or invalid values stop automatic retries rather than retrying early. Native tests exercise a short injected deadline against a real delayed loopback request; their execution is pending macOS.

## First hosted run and redirect correction

Run `44190003046` passed Android and all 67 shared iOS tests. The Swift build succeeded; the cross-origin wire test failed three assertions because Cookie, Referer and a synthetic custom header reached the redirected host. All values were original controlled-fixture values. The redirect handler now constructs a fresh cross-origin GET/HEAD request containing only Accept/User-Agent instead of replacing the proposed request's header dictionary. Cross-origin body-bearing methods are refused. The existing wire assertions remain unchanged and a request-construction regression case is added (46 total Swift cases). Hosted validation of this correction is pending; the earlier native row remains PARTIAL rather than claiming success.

The same first hosted run verified controlled AVPlayer MP4 advancement (1.0002 s), relative HLS with two audio options and one subtitle option, and gated AES-HLS advancement (1.0372 s) with nine audited media requests passing Cookie/User-Agent assertions, including playlist, segment and key requests. Native deadline cancellation, same-origin redirects, errors and single-flight tests passed. This upgrades those specific controlled checks to VERIFIED on that commit; live providers and physical devices remain NOT TESTED. The cross-origin credential boundary remains PARTIAL until the correction passes its unchanged wire test.
