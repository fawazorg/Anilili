"""Verify release plan inputs and publication gates."""
import contextlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import release_plan


class ReleaseVersionTests(unittest.TestCase):
    def run_plan(self, source, mode="dry-run", ref="refs/heads/test", prior=None):
        def git(*args):
            if args == ("tag", "--list", "v*"):
                return "v1.2.3\nv1.2.2" if prior else "v1.2.3"
            if args[0] == "show":
                return prior
            return "expected-sha"

        with tempfile.TemporaryDirectory() as temp, contextlib.chdir(temp):
            Path("app").mkdir()
            Path("app/build.gradle.kts").write_bytes(source)
            with patch.dict(os.environ, GITHUB_OUTPUT="outputs", GITHUB_SHA="expected-sha",
                            RELEASE_MODE=mode, GITHUB_REF=ref), patch.object(release_plan, "git", side_effect=git):
                with patch.object(subprocess, "run") as run:
                    release_plan.main()
                if mode == "publish":
                    run.assert_called_once_with(["git", "merge-base", "--is-ancestor", "expected-sha", "origin/main"],
                                                check=True)
            return Path("outputs").read_text()

    def test_accepts_lf_and_crlf(self):
        for newline in [b"\n", b"\r\n"]:
            with self.subTest(newline=newline):
                source = newline.join([b"val appVersionCode = 97", b'val appVersionName = "0.1.85"', b""])
                self.assertEqual(self.run_plan(source),
                                 "version=0.1.85\nbuild=97\ntag=v0.1.85\nprerelease=false\nmode=dry-run\n")

    def test_accepts_prerelease_and_rejects_invalid_versions(self):
        self.assertIn("prerelease=true", self.run_plan(b'val appVersionCode = 97\nval appVersionName = "1.2.3-beta.1"\n'))
        for source in [b"", b"val appVersionCode = 97\n", b'val appVersionCode = 0\nval appVersionName = "1.2.3"\n',
                       b'val appVersionCode = 97\nval appVersionName = "1.2.3-beta.01"\n']:
            with self.subTest(source=source), self.assertRaises(SystemExit):
                self.run_plan(source)

    def test_publish_requires_matching_tag_and_increasing_build(self):
        source = b'val appVersionCode = 97\nval appVersionName = "1.2.3"\n'
        prior = 'val appVersionCode = 96\nval appVersionName = "1.2.2"\n'
        self.assertIn("mode=publish", self.run_plan(source, "publish", "refs/tags/v1.2.3", prior))
        with self.assertRaisesRegex(SystemExit, "requires the existing"):
            self.run_plan(source, "publish")
        with self.assertRaisesRegex(SystemExit, "must exceed"):
            self.run_plan(source, "publish", "refs/tags/v1.2.3", prior.replace("96", "97"))
