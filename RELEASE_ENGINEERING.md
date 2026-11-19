# Anilili release engineering

The release workflow validates the checked-out commit, builds both Android flavors, and archives the iOS device app after the required simulator tests pass. Its final verification job collects the platform artifacts, version metadata, release notes, and SHA-256 manifest. Only the publication job has repository write permission. GitHub-hosted builds are traceable to their source commit and toolchains. Byte-for-byte reproducibility is unverified.

## Dry run

Run against the branch you intend to release. This builds unsigned Android APKs and the unsigned iOS archive and IPA. It uploads a `verified-release` workflow artifact without making a tag or GitHub Release.

```sh
gh workflow run release.yml --ref feature/phase12-release-engineering -f mode=dry-run
gh run list --workflow release.yml --limit 3
gh run view RUN_ID --log-failed
gh run download RUN_ID -n verified-release -D anilili-release
(cd anilili-release && sha256sum -c SHA256SUMS.txt)
```

## Production setup and first publication

1. In GitHub **Settings → Environments**, configure the `release` environment with required reviewers and deployment tag rules for `v*`, where the repository plan supports them. Protect matching tags with a ruleset so only release maintainers can create them and prevent updates or deletions. Verify the rules before pushing a release tag.
2. Set the existing update-compatible keystore as `ANDROID_KEYSTORE_BASE64` and add `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD` to the release environment secrets. Set `ANDROID_SIGNER_CERT_SHA256` to the 64-digit hex signer digest from a trusted existing release APK, obtained with Android SDK `apksigner verify --print-certs`. Retain the keystore safely for future updates.
3. Set `appVersionName` and increase `appVersionCode` in `app/build.gradle.kts`. Run a dry run, review its artifacts, and merge the intended release revision to main. The tag must match the version and resolve to a commit on main. The build number must exceed previous version tags. Apple receives the numeric version core and the same build number, including for prereleases.
4. After reviewing the dry run and approving publication, create and push the exact version tag. A version tag triggers publication after validation and environment approval. To retry a failed tagged run, dispatch `gh workflow run release.yml --ref vX.Y.Z -f mode=publish`. Existing releases are rejected. If an interrupted upload left an unpublished draft, inspect and delete that draft in GitHub Releases before retrying. Keep the tag at its reviewed commit.

```sh
git tag -a vX.Y.Z VERIFIED_MAIN_SHA -m "Anilili vX.Y.Z"
git push origin refs/tags/vX.Y.Z
```

Publish assets include both universal ARM APKs, legacy APK aliases for existing in-app update clients, the iOS device archive and IPA, platform metadata, release notes, and `SHA256SUMS.txt`. Versions with a prerelease suffix are published as GitHub prereleases. Prefer a higher-version hotfix over replacing an existing release. The Nostr updater manifest is a separate publishing step. For very old clients that select the first APK, choose the correct asset manually.

## Installation

- **Android phone and TV** — Verify checksums, then use the corresponding signed universal APK. For a device connected through ADB, run `adb install -r Anilili-vX.Y.Z-android.apk` or use the `-android-tv.apk` asset for TV. Updates require the existing signing identity. The dry-run APKs require signing before installation.
- **iPhone** — The `-ios-unsigned.ipa` is a Payload ZIP for a compatible local personal-signing tool. Choose your Personal Team, let the tool provision the device and sign the bundle, then install through the tool. Follow its registration and device setup instructions. The original bundle ID is `org.anilili.playbackpoc`. Your Personal Team may require a locally unique identifier, which can change the app's install identity. If your tool cannot sign the artifact, check out the recorded commit, build the arm64 framework, open the Xcode project, select your Personal Team and connected iPhone, and Run with automatic signing. Apple Personal Team profiles expire after seven days. Re-sign and reinstall as needed. [Apple Personal Team limits](https://developer.apple.com/help/account/basics/about-your-developer-account/)

Personal signing and physical installation are **NOT TESTED**. GitHub only produces and verifies the unsigned device package. Apple credentials stay on the local signing machine.
