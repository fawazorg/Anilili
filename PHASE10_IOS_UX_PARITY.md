# Phase 10 iOS UX parity

Phase 9 merged in `e94f122`. Android and Apple CI passed on the merged PR head `ed4f0db` in run 44380019959.

The prototype previously exposed its manual URL player as a primary tab. Browse, Search, Downloads and Settings now each have a clear role. Settings exposes the installed app version and the existing manual player. Downloads confirms deletion and lays out actions vertically when horizontal space runs out. Browse continues to own provider selection, details, episodes and playback. Search retains the separate AniList catalog stack.

| Feature | iOS parity | Remaining gap |
|---|---|---|
| Catalog and search | PARTIAL | Broader Android discovery sections and provider coverage |
| Details and episode playback | PARTIAL | Provider breadth and device-specific playback validation |
| Continue Watching and watched state | PARTIAL | Dedicated library and history views |
| Offline downloads | PARTIAL | Physical-device background and storage recovery |
| Settings | PARTIAL | Supported preferences beyond app information and manual playback |
| Android TV remote focus | NOT APPLICABLE | iPhone uses native touch navigation |

Validation covers the existing CI Python checks and a new simulator navigation test for Downloads and Settings. SwiftUI, offline playback, accessibility on device and Release builds require Apple validation on the Phase 10 changes. Physical iPhone, VoiceOver and layout across device sizes remain NOT TESTED.

After Phase 10 validation, Phase 11 can address library parity and physical-device playback and offline recovery.
