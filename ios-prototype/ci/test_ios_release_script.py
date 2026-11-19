"""Validate release inputs without requiring Xcode or pretending to build iOS."""
import os
from pathlib import Path
import subprocess
import unittest
import tempfile


class IOSReleaseScriptTests(unittest.TestCase):
    script = Path(__file__).resolve().parents[2] / 'scripts/release_ios.sh'

    def run_input(self, version, build):
        # Invalid inputs must fail before platform/toolchain checks on every host.
        with tempfile.TemporaryDirectory() as directory:
            uname = Path(directory) / 'uname'
            uname.write_text('#!/bin/sh\necho Linux\n')
            uname.chmod(0o755)
            return subprocess.run(['bash', str(self.script)], env={**os.environ,
                'PATH': directory + os.pathsep + os.environ['PATH'],
                'RELEASE_VERSION': version, 'RELEASE_BUILD': build}, capture_output=True, text=True)

    def test_rejects_invalid_semver_before_build(self):
        for version in ['', 'v1.2.3', '1.2', '01.2.3', '1.2.3-01', '../file', '1.2.3/evil']:
            with self.subTest(version=version):
                result = self.run_input(version, '1')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('RELEASE_VERSION must be SemVer', result.stderr)

    def test_rejects_invalid_build_before_build(self):
        for build in ['', '0', '-1', '1.2', '01', 'text']:
            with self.subTest(build=build):
                result = self.run_input('1.2.3-rc.1+build.5', build)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('RELEASE_BUILD must be a positive integer', result.stderr)

    def test_valid_inputs_stop_explicitly_on_linux(self):
        for version in ['0.1.0', '1.2.3-rc.1', '1.2.3+build.10']:
            result = self.run_input(version, '12')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('requires macOS with Xcode', result.stderr)
