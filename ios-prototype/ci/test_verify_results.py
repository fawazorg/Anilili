from pathlib import Path
import tempfile
import unittest

from verify_results import verify


class SimulatorResultsTests(unittest.TestCase):
    def make_suites(self, root):
        directory = root / "Tests"
        directory.mkdir()
        (directory / "PlaybackTests.swift").write_text("func testPlayback() {}")
        (directory / "CatalogTests.swift").write_text("func testSearch() {}\nfunc testDetails() {}")
        (directory / "JourneyTests.swift").write_text("func testEpisodeSelectionProgressAndBack() {}")
        ui = root / "UITests"
        ui.mkdir()
        (ui / "JourneyUITests.swift").write_text("func testVisibleCatalogToPlaybackAndBack() {}")
        (directory / "WatchHistoryTests.swift").write_text("func testPersistence() {}")
        (ui / "WatchHistoryUITests.swift").write_text("func testResumeAfterRestart() {}")
        (directory / "ProviderCompatibilityTests.swift").write_text("func testProviderPlayback() {}")
        (directory / "LifecycleTests.swift").write_text("func testLifecycle() {}")
        (directory / "DiagnosticsTests.swift").write_text("func testRedaction() {}")
        (ui / "AccessibilityUITests.swift").write_text("func testAccessibleNavigation() {}")
        (directory / "ExpandedProviderJourneyTests.swift").write_text("func testExpandedProviderJourney() {}")
        (directory / "OfflineDownloadTests.swift").write_text("func testOfflineDownload() {}")
        (directory / "OfflineJourneyTests.swift").write_text("func testOfflineJourney() {}")
        return directory

    def test_requires_all_suites_and_rejects_skipped_failed_or_missing_tests(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = self.make_suites(Path(temp))
            summary = dict(totalTestCount=14, passedTests=14, failedTests=0, skippedTests=0)
            self.assertEqual(verify(summary, directory), 14)
            for overrides in [dict(totalTestCount=1, passedTests=1),
                              dict(passedTests=10, failedTests=1),
                              dict(passedTests=10, skippedTests=1),
                              dict(totalTestCount=0, passedTests=0),
                              dict(totalTestCount=15, passedTests=15)]:
                with self.subTest(overrides=overrides):
                    with self.assertRaises(ValueError):
                        verify(summary | overrides, directory)

    def test_missing_or_empty_journey_suite_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = self.make_suites(Path(temp))
            journey = directory / "JourneyTests.swift"
            journey.unlink()
            summary = dict(totalTestCount=10, passedTests=10, failedTests=0, skippedTests=0)
            with self.assertRaises(ValueError):
                verify(summary, directory)
            journey.write_text("// No executed journey tests")
            with self.assertRaises(ValueError):
                verify(summary, directory)

    def test_missing_or_empty_ui_journey_suite_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = self.make_suites(Path(temp))
            journey = Path(temp) / "UITests" / "JourneyUITests.swift"
            journey.unlink()
            summary = dict(totalTestCount=10, passedTests=10, failedTests=0, skippedTests=0)
            with self.assertRaises(ValueError):
                verify(summary, directory)
            journey.write_text("// No executed UI journey tests")
            with self.assertRaises(ValueError):
                verify(summary, directory)

    def test_history_and_resume_suites_are_required(self):
        for relative in ["Tests/OfflineDownloadTests.swift", "Tests/OfflineJourneyTests.swift", "Tests/ExpandedProviderJourneyTests.swift", "Tests/LifecycleTests.swift", "Tests/DiagnosticsTests.swift", "UITests/AccessibilityUITests.swift", "Tests/WatchHistoryTests.swift", "UITests/WatchHistoryUITests.swift", "Tests/ProviderCompatibilityTests.swift"]:
            with tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                directory = self.make_suites(root)
                required = root / relative
                required.unlink()
                summary = dict(totalTestCount=10, passedTests=10, failedTests=0, skippedTests=0)
                with self.assertRaises(ValueError):
                    verify(summary, directory)
                required.write_text("// Required history tests missing")
                with self.assertRaises(ValueError):
                    verify(summary, directory)

    def test_empty_test_directory_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ValueError):
                verify({}, Path(temp) / "Tests")


if __name__ == "__main__":
    unittest.main()
