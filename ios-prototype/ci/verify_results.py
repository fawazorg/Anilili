"""Reject absent, skipped, failed, or incomplete simulator test runs."""
import json
from pathlib import Path
import re
import sys

summary = json.loads(Path(sys.argv[1]).read_text())
source = Path(__file__).resolve().parents[1] / "Tests" / "PlaybackTests.swift"
required = len(re.findall(r"\bfunc\s+test\w+\s*\(", source.read_text()))
passed = summary.get("passedTests", 0)
failed = summary.get("failedTests", 0)
skipped = summary.get("skippedTests", 0)
total = summary.get("totalTestCount", 0)
if required == 0 or total != required or passed != required or failed or skipped:
    raise SystemExit(f"Incomplete simulator tests: required={required}, total={total}, passed={passed}, failed={failed}, skipped={skipped}")
print(f"Verified {passed} executed simulator tests; playback assertions are in PlaybackTests.")
