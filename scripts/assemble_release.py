#!/usr/bin/env python3
"""Verify files from the platform jobs and stage this run's release payload."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

from release_plan import git, version_from_script


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def copy_assets(source, output, names):
    for name in names:
        item = source / name
        require(item.is_file() and not item.is_symlink() and item.stat().st_size, f"Missing or empty artifact: {name}")
        shutil.copyfile(item, output / name)


def main():
    version, build, _ = version_from_script(Path("app/build.gradle.kts").read_text())
    mode = os.environ["RELEASE_MODE"]
    require(mode in {"publish", "dry-run"}, "Invalid release mode")
    require(version == os.environ["RELEASE_VERSION"] and str(build) == os.environ["RELEASE_BUILD"],
            "Release plan differs from checkout")
    signed = mode == "publish"
    source = Path("release-input")
    android_path = source / "release-android"
    ios_path = source / "release-ios"
    android_metadata = "android-build.json"
    ios_metadata = "ios-build-metadata.json"
    android = json.loads((android_path / android_metadata).read_text())
    ios = json.loads((ios_path / ios_metadata).read_text())
    revision = git("rev-parse", "HEAD")
    require(revision == os.environ["GITHUB_SHA"], "Verification checkout differs from workflow commit")
    require(android["commit"] == revision and android["configuration"] == "Release" and android["version"] == version and android["version_code"] == build and
            android["package_id"] == "com.miruronative" and android["min_sdk"] == 22 and
            android["target_sdk"] == 36 and android["signing"] == ("signed" if signed else "unsigned"),
            "Unexpected Android release metadata")
    require(not signed or re.fullmatch(r"[0-9a-fA-F]{64}", android["signer_certificate_sha256"] or ""),
            "Android release signer digest is missing")
    require(ios["releaseVersion"] == version and ios["appleVersion"] == version.split("-", 1)[0] and
            ios["buildNumber"] == str(build) and ios["sourceCommit"] == revision and not ios["sourceTreeDirty"] and
            ios["platform"] == "iphoneos" and ios["architectures"] == ["arm64"] and ios["signed"] is False,
            "Unexpected iOS release metadata")

    suffix = "" if signed else "-unsigned"
    android_files = [f"Anilili-v{version}-android{flavor}{suffix}.apk" for flavor in ("", "-tv")]
    ios_files = [f"Anilili-v{version}-ios-{suffix}" for suffix in ("unsigned.ipa", "device.xcarchive.zip")]
    aliases = ["Anilili.apk", "Anilili_tv.apk"] if signed else []
    output = Path("dist")
    output.mkdir()
    copy_assets(android_path, output, [*android_files, *aliases, android_metadata])
    copy_assets(ios_path, output, [*ios_files, ios_metadata])
    for alias, canonical in zip(aliases, android_files):
        require(digest(output / alias) == digest(output / canonical), f"APK alias differs: {alias}")
    for name in ios_files:
        item = output / name
        require(ios["artifacts"][name] == {"sha256": digest(item), "bytes": item.stat().st_size},
                f"iOS artifact integrity mismatch: {name}")

    previous = subprocess.run(["git", "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", "HEAD^"],
                              capture_output=True, text=True).stdout.strip()
    changes = git("log", "--first-parent", "--format=- %s (%h)", "-n", "30",
                  f"{previous}..HEAD" if previous else "HEAD")
    (output / "RELEASE_NOTES.md").write_text(
        f"# Anilili v{version}\n\nBuild {build} from `{revision}` on {os.environ['RELEASE_BUILD_DATE']}.\n\n"
        "The iOS arm64 archive and IPA require personal signing and provisioning before installation. "
        "Physical-device installation has not been verified by this workflow.\n\n"
        + ("" if signed else "The Android dry-run APKs are unsigned.\n\n")
        + f"## Changes\n\n{changes}\n"
    )
    entries = sorted(output.iterdir())
    (output / "SHA256SUMS.txt").write_text("".join(f"{digest(p)}  {p.name}\n" for p in entries))


if __name__ == "__main__":
    main()
