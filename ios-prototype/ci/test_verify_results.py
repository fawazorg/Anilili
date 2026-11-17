from pathlib import Path
import tempfile
import unittest

from verify_results import verify


class SimulatorResultsTests(unittest.TestCase):
    def test_requires_all_suites_and_rejects_skipped_failed_or_missing_tests(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / "PlaybackTests.swift").write_text("func testPlayback() {}")
            (directory / "CatalogTests.swift").write_text("func testSearch() {}\nfunc testDetails() {}")
            summary = dict(totalTestCount=3, passedTests=3, failedTests=0, skippedTests=0)
            self.assertEqual(verify(summary, directory), 3)
            for overrides in [dict(totalTestCount=1, passedTests=1),
                              dict(passedTests=2, failedTests=1),
                              dict(passedTests=2, skippedTests=1),
                              dict(totalTestCount=0, passedTests=0),
                              dict(totalTestCount=4, passedTests=4)]:
                with self.subTest(overrides=overrides):
                    with self.assertRaises(ValueError):
                        verify(summary | overrides, directory)

    def test_empty_test_directory_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ValueError):
                verify({}, Path(temp))


if __name__ == "__main__":
    unittest.main()
