"""Check that publication packaging rejects mismatched artifacts."""
import contextlib
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import assemble_release


class ReleasePayloadTests(unittest.TestCase):
    def verify_fixture(self, corrupt=False):
        with tempfile.TemporaryDirectory() as temp, contextlib.chdir(temp):
            Path("app").mkdir()
            Path("app/build.gradle.kts").write_text('val appVersionCode = 97\nval appVersionName = "0.1.85"\n')
            android = Path("release-input/release-android")
            apple = Path("release-input/release-ios")
            android.mkdir(parents=True)
            apple.mkdir(parents=True)
            for suffix in ["android-unsigned.apk", "android-tv-unsigned.apk"]:
                (android / f"Anilili-v0.1.85-{suffix}").write_bytes(suffix.encode())
            (android / "android-build.json").write_text(json.dumps(dict(
                version="0.1.85", version_code=97, package_id="com.miruronative", min_sdk=22,
                target_sdk=36, signing="unsigned", commit="tested-revision", configuration="Release"
            )))
            artifacts = {}
            for suffix in ["unsigned.ipa", "device.xcarchive.zip"]:
                name = f"Anilili-v0.1.85-ios-{suffix}"
                content = suffix.encode()
                artifacts[name] = {"sha256": hashlib.sha256(content).hexdigest(), "bytes": len(content)}
                (apple / name).write_bytes(content if not corrupt else b"corrupt")
            (apple / "ios-build-metadata.json").write_text(json.dumps(dict(
                releaseVersion="0.1.85", appleVersion="0.1.85", buildNumber="97",
                sourceCommit="tested-revision", sourceTreeDirty=False, platform="iphoneos",
                architectures=["arm64"], signed=False, artifacts=artifacts
            )))
            with patch.dict(os.environ, GITHUB_SHA="tested-revision", RELEASE_BUILD_DATE="2026-11-19",
                            RELEASE_MODE="dry-run", RELEASE_VERSION="0.1.85", RELEASE_BUILD="97"):
                with patch.object(assemble_release, "git", return_value="tested-revision"), \
                     patch.object(assemble_release.subprocess, "run") as run:
                    run.return_value.stdout = ""
                    assemble_release.main()
            manifest = Path("dist/SHA256SUMS.txt").read_text()
            for row in manifest.splitlines():
                sha256, name = row.split("  ", 1)
                self.assertEqual(sha256, hashlib.sha256((Path("dist") / name).read_bytes()).hexdigest())
            self.assertEqual(len(manifest.splitlines()), 7)

    def test_dry_run_stages_complete_checksummed_payload(self):
        self.verify_fixture()

    def test_corrupt_artifact_cannot_produce_checksum_manifest(self):
        with self.assertRaisesRegex(SystemExit, "integrity mismatch"):
            self.verify_fixture(corrupt=True)
