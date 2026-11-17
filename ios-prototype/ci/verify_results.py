"""Reject absent, skipped, failed, or incomplete simulator test runs."""
import json
from pathlib import Path
import re
import sys

def verify(summary, tests_directory):
    sources = sorted(tests_directory.glob("*Tests.swift"))
    sources += sorted((tests_directory.parent / "UITests").glob("*Tests.swift"))
    counts = {str(source.relative_to(tests_directory.parent)): len(re.findall(r"\bfunc\s+test\w+\s*\(", source.read_text())) for source in sources}
    required_suites = {"Tests/PlaybackTests.swift", "Tests/CatalogTests.swift", "Tests/JourneyTests.swift", "UITests/JourneyUITests.swift", "Tests/WatchHistoryTests.swift", "UITests/WatchHistoryUITests.swift"}
    if not required_suites.issubset(counts) or any(counts[name] == 0 for name in required_suites):
        raise ValueError("Required playback, catalog, journey, history, and UI suites must contain tests")
    required = sum(counts.values())
    passed = summary.get("passedTests", 0)
    failed = summary.get("failedTests", 0)
    skipped = summary.get("skippedTests", 0)
    total = summary.get("totalTestCount", 0)
    if required == 0 or total != required or passed != required or failed or skipped:
        raise ValueError(f"Incomplete simulator tests: required={required}, total={total}, passed={passed}, failed={failed}, skipped={skipped}")
    return passed


if __name__ == "__main__":
    summary = json.loads(Path(sys.argv[1]).read_text())
    try:
        passed = verify(summary, Path(__file__).resolve().parents[1] / "Tests")
    except ValueError as error:
        raise SystemExit(str(error))
    print(f"Verified {passed} executed simulator tests across playback, catalog, integration journey, and UI journey suites.")
