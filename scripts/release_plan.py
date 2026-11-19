#!/usr/bin/env python3
"""Validate the version, build number, and Git ref before release jobs start."""
import os
from pathlib import Path
import re
import subprocess

SEMVER = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-((?:[0-9A-Za-z-]+\.)*[0-9A-Za-z-]+))?"
)


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def version_from_script(script):
    name = re.search(r'^val appVersionName = "([^"]+)"$', script, re.M)
    code = re.search(r"^val appVersionCode = ([0-9]+)$", script, re.M)
    if name is None or code is None:
        raise SystemExit("Canonical release version or build number is missing")
    version = name[1]
    match = SEMVER.fullmatch(version)
    if not match or any(
        part.isdigit() and len(part) > 1 and part.startswith("0")
        for part in (match[4] or "").split(".")
    ):
        raise SystemExit(f"Invalid semantic version: {version}")
    build = int(code[1])
    if not 1 <= build <= 2_100_000_000:
        raise SystemExit("Build number is outside the Android versionCode range")
    return version, build, match[4] is not None


def main():
    mode = os.environ["RELEASE_MODE"]
    if mode not in {"dry-run", "publish"}:
        raise SystemExit("Unknown release mode")
    version, build, prerelease = version_from_script(Path("app/build.gradle.kts").read_text())
    tag = f"v{version}"
    revision = git("rev-parse", "HEAD")
    if revision != os.environ["GITHUB_SHA"]:
        raise SystemExit("Checkout differs from the workflow commit")
    if mode == "publish":
        if os.environ["GITHUB_REF"] != f"refs/tags/{tag}" or git("rev-parse", f"{tag}^{{commit}}") != revision:
            raise SystemExit(f"Publication requires the existing {tag} tag at this commit")
        subprocess.run(["git", "merge-base", "--is-ancestor", revision, "origin/main"], check=True)
        for previous in git("tag", "--list", "v*").splitlines():
            if previous == tag or not SEMVER.fullmatch(previous[1:]):
                continue
            _, old_build, _ = version_from_script(git("show", f"{previous}:app/build.gradle.kts"))
            if build <= old_build:
                raise SystemExit(f"Build {build} must exceed build {old_build} at {previous}")

    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        for key, value in {
            "version": version, "build": build, "tag": tag,
            "prerelease": str(prerelease).lower(), "mode": mode,
        }.items():
            print(f"{key}={value}", file=output)


if __name__ == "__main__":
    main()
