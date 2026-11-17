"""Reject absent, skipped, failed, or incomplete simulator test runs."""
import json
from pathlib import Path
import re
import sys

def verify(summary, tests_directory):
    sources = sorted(tests_directory.glob("*Tests.swift"))
    required = sum(len(re.findall(r"\bfunc\s+test\w+\s*\(", source.read_text())) for source in sources)
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
    print(f"Verified {passed} executed simulator tests across playback and catalog suites.")
