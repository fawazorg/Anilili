#!/usr/bin/env bash
set -euo pipefail

: "${RELEASE_VERSION:?Set the canonical Android version name}"
: "${RELEASE_BUILD:?Set the canonical Android build number}"
: "${RELEASE_MODE:?Set dry-run or publish}"

fail() { echo "$*" >&2; exit 1; }
[[ "$RELEASE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]] ||
    fail "Invalid release version"
[[ "$RELEASE_BUILD" =~ ^[1-9][0-9]*$ ]] || fail "Invalid release build number"
[[ "$RELEASE_MODE" == dry-run || "$RELEASE_MODE" == publish ]] || fail "Invalid release mode"
expected_signer=${ANDROID_SIGNER_CERT_SHA256:-}
if [[ "$RELEASE_MODE" == publish || -n "$expected_signer" ]]; then
    [[ "$expected_signer" =~ ^[0-9a-fA-F]{64}$ ]] || fail "Expected Android signer must be a SHA-256 hex digest"
fi

sdk_root=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
[[ -n "$sdk_root" ]] || fail "Android SDK path is required"
build_tools="$sdk_root/build-tools/35.0.1"
for tool in aapt apksigner zipalign; do
    [[ -x "$build_tools/$tool" ]] || fail "Missing Android build tool: $tool"
done

umask 077
signing_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/anilili-android-signing.XXXXXXXX")
trap 'rm -f -- "$signing_dir/release.keystore" "$signing_dir/mobile-signature.txt" "$signing_dir/tv-signature.txt"; rmdir -- "$signing_dir"' EXIT
export ANILILI_RELEASE_SIGNING=unsigned
if [[ -n "${ANDROID_KEYSTORE_BASE64:-}" || -n "${ANDROID_KEYSTORE_PASSWORD:-}" ||
      -n "${ANDROID_KEY_ALIAS:-}" || -n "${ANDROID_KEY_PASSWORD:-}" ]]; then
    [[ -n "${ANDROID_KEYSTORE_BASE64:-}" && -n "${ANDROID_KEYSTORE_PASSWORD:-}" &&
       -n "${ANDROID_KEY_ALIAS:-}" && -n "${ANDROID_KEY_PASSWORD:-}" ]] ||
        fail "Android signing configuration is incomplete"
    printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 --decode > "$signing_dir/release.keystore"
    [[ -s "$signing_dir/release.keystore" ]] || fail "Android signing keystore is empty"
    export ANILILI_RELEASE_SIGNING=signed
    export ANILILI_KEYSTORE_PATH="$signing_dir/release.keystore"
elif [[ "$RELEASE_MODE" == publish ]]; then
    fail "Publication requires the persistent Android release keystore"
fi
unset ANDROID_KEYSTORE_BASE64

# Signing values must never be written to Gradle's configuration cache or retained
# in a reusable daemon. An offline dry run may pass --offline.
./gradlew :app:testMobileReleaseUnitTest --rerun :app:testTvReleaseUnitTest --rerun \
    :app:assembleMobileRelease :app:assembleTvRelease -x :app:syncParityCorpus \
    --no-configuration-cache --no-daemon "$@"

mkdir -p dist
suffix=
[[ "$ANILILI_RELEASE_SIGNING" != unsigned ]] || suffix=-unsigned
signer=
for flavor in mobile tv; do
    expected_variant="${flavor}Release"
    output_dir="app/build/outputs/apk/$flavor/release"
    # AGP records which APK is universal. Flavor provenance comes from the
    # metadata because both flavors deliberately share the installed package ID.
    apk=$(python3 - "$output_dir/output-metadata.json" "$expected_variant" <<'PY'
import json
from pathlib import Path
import sys

metadata = Path(sys.argv[1])
data = json.loads(metadata.read_text())
if data.get("variantName") != sys.argv[2] or data.get("applicationId") != "com.miruronative":
    sys.exit("Unexpected Android APK output variant")
outputs = [item["outputFile"] for item in data["elements"] if not item.get("filters")]
if len(outputs) != 1 or Path(outputs[0]).name != outputs[0]:
    sys.exit("Expected exactly one universal APK for each Android flavor")
print(metadata.parent / outputs[0])
PY
    )
    [[ -s "$apk" ]] || fail "Missing universal $flavor APK"
    badging=$("$build_tools/aapt" dump badging "$apk")
    [[ "$badging" == *"package: name='com.miruronative' versionCode='$RELEASE_BUILD' versionName='$RELEASE_VERSION'"* &&
       "$badging" == *"sdkVersion:'22'"* && "$badging" == *"targetSdkVersion:'36'"* &&
       "$badging" == *"compileSdkVersion='36'"* ]] || fail "Unexpected package, version or SDK metadata in $flavor APK"
    abi_line=$(grep '^native-code:' <<< "$badging")
    [[ "$abi_line" == *"'arm64-v8a'"* && "$abi_line" == *"'armeabi-v7a'"* ]] || fail "Expected both ARM ABIs in $flavor APK"
    "$build_tools/zipalign" -c 4 "$apk"
    signature_log="$signing_dir/$flavor-signature.txt"
    if [[ "$ANILILI_RELEASE_SIGNING" == signed ]]; then
        "$build_tools/apksigner" verify --min-sdk-version 22 --print-certs "$apk" > "$signature_log"
        if grep -Ei '^Signer #[0-9]+ certificate DN:.*CN=Android Debug([,]|$)' "$signature_log"; then
            fail "Debug certificate found in $flavor release APK"
        fi
        digest=$(sed -n 's/^Signer #1 certificate SHA-256 digest: //p' "$signature_log")
        [[ "$digest" =~ ^[0-9a-fA-F]{64}$ && -z $(grep '^Signer #2 certificate SHA-256 digest:' "$signature_log") ]] ||
            fail "Expected a single Android signing certificate"
        [[ -z "$signer" || "$signer" == "$digest" ]] || fail "Android flavor signing identities differ"
        [[ -z "$expected_signer" || "${expected_signer,,}" == "${digest,,}" ]] ||
            fail "Unexpected Android signing certificate in $flavor APK"
        signer=$digest
    else
        if "$build_tools/apksigner" verify --min-sdk-version 22 "$apk" > "$signature_log" 2>&1; then
            fail "$flavor dry-run APK was unexpectedly signed"
        fi
        grep -Fq 'No JAR signatures' "$signature_log" || fail "$flavor APK did not verify as intentionally unsigned"
    fi

    flavor_suffix=
    legacy=Anilili.apk
    if [[ "$flavor" == tv ]]; then
        flavor_suffix=-tv
        legacy=Anilili_tv.apk
    fi
    canonical="dist/Anilili-v$RELEASE_VERSION-android$flavor_suffix$suffix.apk"
    cp -- "$apk" "$canonical"
    if [[ "$RELEASE_MODE" == publish ]]; then
        # Existing Android clients recognize this older naming convention.
        cp -- "$canonical" "dist/$legacy"
    fi
done

java_bin=${JAVA_HOME:+$JAVA_HOME/bin/}java
python3 - "$ANILILI_RELEASE_SIGNING" "$signer" "$RELEASE_VERSION" "$RELEASE_BUILD" "$java_bin" <<'PY'
import json
from pathlib import Path
import re
import subprocess
import sys
import tomllib

signing, certificate, version, build, java_bin = sys.argv[1:]
wrapper = Path("gradle/wrapper/gradle-wrapper.properties").read_text()
gradle = re.search(r"^distributionUrl=.*?/gradle-([0-9.]+)-bin\.zip$", wrapper, re.MULTILINE)
if not gradle:
    sys.exit("Could not read the Gradle wrapper version")
with Path("gradle/libs.versions.toml").open("rb") as catalog:
    kotlin = tomllib.load(catalog)["versions"]["kotlin"]
metadata = {
    "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "configuration": "Release",
    "java": subprocess.check_output([java_bin, "-version"], text=True, stderr=subprocess.STDOUT).splitlines()[0],
    "gradle": gradle[1],
    "kotlin": kotlin,
    "package_id": "com.miruronative",
    "version": version,
    "version_code": int(build),
    "min_sdk": 22,
    "target_sdk": 36,
    "compile_sdk": 36,
    "build_tools": "35.0.1",
    "abis": ["armeabi-v7a", "arm64-v8a"],
    "signing": signing,
    "signer_certificate_sha256": certificate or None,
}
Path("dist/android-build.json").write_text(json.dumps(metadata, indent=2) + "\n")
PY
