# Phase 10 iOS UX parity

Phase 9 merged in `e94f122`. Android and Apple CI passed on the merged PR head `ed4f0db` in run 44380019959.

The prototype previously exposed its manual URL player as a primary tab. Browse, Search, Downloads and Settings now each have a clear role. Settings exposes the installed app version and the existing manual player. Downloads confirms deletion and lays out actions vertically when horizontal space runs out. Browse uses the same cover component as Search and keeps Continue Watching in the scrolling list even during catalog errors. Episode rows show completed downloads from the existing download engine. The video surface scales with available width, and the player gives distinct loading and buffering feedback. Browse continues to own provider selection, details, episodes and playback. Search retains the separate AniList catalog stack.

| Feature | iOS parity | Remaining gap |
|---|---|---|
| Catalog and search | PARTIAL | Broader Android discovery sections and provider coverage |
| Details and episode playback | PARTIAL | Provider breadth and device-specific playback validation |
| Continue Watching and watched state | PARTIAL | Dedicated library and history views |
| Offline downloads | PARTIAL | Physical-device background and storage recovery |
| Settings | PARTIAL | Supported preferences beyond app information and manual playback |
| Android TV remote focus | NOT APPLICABLE | iPhone uses native touch navigation |

PASS on Linux for both Android debug builds, all 115 shared JVM tests, and 2,578 unit tests per Android flavor. Five tests per flavor were skipped by the existing suite. All 29 local Python checks and the whitespace check also passed. The simulator navigation test covers Downloads, Settings, and restoring the Settings destination after switching tabs. SwiftUI, offline playback, accessibility on device and Release builds require Apple validation on the Phase 10 changes. Physical iPhone, VoiceOver and layout across device sizes remain NOT TESTED. GitHub Actions is manual only and requires a published Phase 10 revision.

After Phase 10 validation, Phase 11 can address library parity and physical-device playback and offline recovery.
