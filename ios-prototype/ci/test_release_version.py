"""Exercise the real release version step against LF/CRLF Gradle inputs."""
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


class ReleaseVersionTests(unittest.TestCase):
    def run_step(self, source):
        workflow = Path(__file__).resolve().parents[2] / '.github/workflows/release.yml'
        step = workflow.read_text().split('      - name: Read version\n', 1)[1]
        script = textwrap.dedent(step.split('        run: |\n', 1)[1].split('\n      - name:', 1)[0])
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'app').mkdir()
            (root / 'app/build.gradle.kts').write_bytes(source)
            output = root / 'outputs'
            result = subprocess.run(['bash', '-eo', 'pipefail', '-c', script], cwd=root,
                env={**os.environ, 'GITHUB_OUTPUT': str(output)}, capture_output=True, text=True)
            return result, output.read_text() if output.exists() else ''

    def test_real_version_step_accepts_lf_and_crlf_without_carriage_returns(self):
        for newline in [b'\n', b'\r\n']:
            with self.subTest(newline=newline):
                source = newline.join([b'val appVersionCode = 97', b'val appVersionName = "0.1.85"', b''])
                result, output = self.run_step(source)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output, 'version=0.1.85\ncode=97\ntag=v0.1.85\n')

    def test_real_version_step_rejects_missing_or_invalid_values(self):
        for source in [b'', b'val appVersionCode = 97\n',
                       b'val appVersionCode = invalid\nval appVersionName = "0.1.85"\n']:
            with self.subTest(source=source):
                result, output = self.run_step(source)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Could not read', result.stderr)
                self.assertEqual(output, '')
