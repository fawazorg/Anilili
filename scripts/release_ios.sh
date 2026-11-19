#!/usr/bin/env bash
# Produce an unsigned device archive and re-signable IPA; no signing or upload.
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
cd "$project_directory"

apple_version="$(python3 - <<'PY'
import os, re
version = os.environ.get('RELEASE_VERSION', '')
match = re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?', version)
if not match or (match[4] and any(part.isdigit() and len(part) > 1 and part.startswith('0') for part in match[4].split('.'))):
    raise SystemExit('RELEASE_VERSION must be SemVer without a v prefix')
build = os.environ.get('RELEASE_BUILD', '')
if not re.fullmatch(r'[1-9][0-9]*', build):
    raise SystemExit('RELEASE_BUILD must be a positive integer')
print('.'.join(match.group(i) for i in (1, 2, 3)))
PY
)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Unsigned iOS release requires macOS with Xcode and the iPhoneOS SDK.' >&2
  exit 1
fi
for tool in xcodebuild xcrun ditto codesign; do command -v "$tool" >/dev/null; done
xcrun --sdk iphoneos --show-sdk-version
mkdir -p dist
release_temporary="$(mktemp -d "${TMPDIR:-/tmp}/anilili-ios-release.XXXXXX")"
trap 'rmdir "$release_temporary" 2>/dev/null || true' EXIT
# Keep failed build evidence in the temporary directory; never delete user data.
archive="$release_temporary/Anilili.xcarchive"
settings="$release_temporary/build-settings.json"
common=(-project ios-prototype/PlaybackPOC.xcodeproj -scheme PlaybackPOC
        -configuration Release -sdk iphoneos -destination 'generic/platform=iOS'
        "MARKETING_VERSION=$apple_version" "CURRENT_PROJECT_VERSION=$RELEASE_BUILD"
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)

framework=shared-core/build/bin/iosArm64/releaseFramework/SharedCore.framework/SharedCore
if [[ "${RELEASE_IOS_FRAMEWORK_READY:-0}" == 1 ]]; then
  test -f "$framework"
  [[ "$(xcrun lipo -archs "$framework")" == arm64 ]]
else
  ./gradlew :shared-core:linkReleaseFrameworkIosArm64 --stacktrace
fi
xcodebuild -showBuildSettings -json "${common[@]}" > "$settings"
python3 ios-prototype/ci/verify_release_settings.py "$settings" iphoneos
xcodebuild archive "${common[@]}" -archivePath "$archive" \
  -derivedDataPath "$release_temporary/DerivedData" SKIP_INSTALL=NO \
  2>&1 | tee dist/ios-archive.log

app="$archive/Products/Applications/PlaybackPOC.app"
test -f "$app/Info.plist"
test -f "$app/PrivacyInfo.xcprivacy"
export IOS_RELEASE_APP="$app" IOS_RELEASE_APPLE_VERSION="$apple_version"
python3 - <<'PY'
import os, pathlib, plistlib
app = pathlib.Path(os.environ['IOS_RELEASE_APP'])
info = plistlib.loads((app / 'Info.plist').read_bytes())
expected = {'CFBundleIdentifier': 'org.anilili.playbackpoc',
            'CFBundleShortVersionString': os.environ['IOS_RELEASE_APPLE_VERSION'],
            'CFBundleVersion': os.environ['RELEASE_BUILD'], 'CFBundleSupportedPlatforms': ['iPhoneOS'],
            'MinimumOSVersion': '17.0'}
for key, value in expected.items():
    if info.get(key) != value:
        raise SystemExit(f'Archived app has incorrect {key}')
if info.get('UIBackgroundModes'):
    raise SystemExit('Unexpected background capabilities in release app')
if info.get('NSAppTransportSecurity', {}).get('NSAllowsArbitraryLoads'):
    raise SystemExit('Global App Transport Security exception is prohibited')
PY
architectures="$(xcrun lipo -archs "$app/PlaybackPOC")"
if [[ "$architectures" != arm64 ]]; then
  echo "Expected arm64 device executable; got: $architectures" >&2; exit 1
fi
if codesign -d "$app" >/dev/null 2>&1; then
  echo 'Expected unsigned archive but found an app signature.' >&2; exit 1
fi
# Preserve release diagnostic evidence when this archive replaces the CI device build.
if [[ -d ios-prototype/Results ]]; then
  cp "$settings" ios-prototype/Results/release-Device-settings.json
  xcrun nm -u "$app/PlaybackPOC" > ios-prototype/Results/release-Device-undefined-symbols.txt
fi
mkdir "$release_temporary/Payload"
ditto "$app" "$release_temporary/Payload/PlaybackPOC.app"
ditto -c -k --keepParent "$release_temporary/Payload" "dist/Anilili-v${RELEASE_VERSION}-ios-unsigned.ipa"
ditto -c -k --keepParent "$archive" "dist/Anilili-v${RELEASE_VERSION}-ios-device.xcarchive.zip"
xcodebuild -version > "$release_temporary/xcode-version.txt"
xcrun --sdk iphoneos --show-sdk-version > "$release_temporary/sdk-version.txt"
export IOS_RELEASE_TEMPORARY="$release_temporary"
python3 - <<'PY'
import hashlib, json, os, pathlib, subprocess, zipfile
root = pathlib.Path.cwd()
temp = pathlib.Path(os.environ['IOS_RELEASE_TEMPORARY'])
dist = root / 'dist'
version = os.environ['RELEASE_VERSION']
files = [dist / f'Anilili-v{version}-ios-unsigned.ipa', dist / f'Anilili-v{version}-ios-device.xcarchive.zip']
with zipfile.ZipFile(files[0]) as ipa:
    if 'Payload/PlaybackPOC.app/Info.plist' not in ipa.namelist():
        raise SystemExit('IPA is missing Payload application')
def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()
metadata = dict(releaseVersion=version, appleVersion=os.environ['IOS_RELEASE_APPLE_VERSION'],
    buildNumber=os.environ['RELEASE_BUILD'], signed=False, platform='iphoneos', architectures=['arm64'],
    sourceCommit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    sourceTreeDirty=bool(subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], text=True).strip()),
    xcode=(temp / 'xcode-version.txt').read_text().strip(), sdk=(temp / 'sdk-version.txt').read_text().strip(),
    runnerImage=os.environ.get('ImageOS'), runnerImageVersion=os.environ.get('ImageVersion'),
    gradleWrapperSha256=sha256(root / 'gradle/wrapper/gradle-wrapper.properties'),
    dependencyCatalogSha256=sha256(root / 'gradle/libs.versions.toml'),
    releaseScriptSha256=sha256(root / 'scripts/release_ios.sh'),
    sharedFrameworkSha256=sha256(root / 'shared-core/build/bin/iosArm64/releaseFramework/SharedCore.framework/SharedCore'),
    limitations=['Unsigned: requires legitimate Apple signing and provisioning before device installation.',
                  'Not a TestFlight export; physical-device playback and privacy audit remain separate validation.'],
    artifacts={p.name: dict(bytes=p.stat().st_size, sha256=sha256(p)) for p in files})
(dist / 'ios-build-metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
PY
printf 'Unsigned iPhone archive and re-signable IPA created in dist/. Build evidence: %s\n' "$release_temporary"
