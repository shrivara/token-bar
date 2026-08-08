#!/bin/bash
# Bumps the patch component of the app version in every place it is embedded.
set -euo pipefail

cd "$(dirname "$0")/.."

build_version=$(awk '
    /<key>CFBundleShortVersionString<\/key>/ { getline; gsub(/.*<string>|<\/string>.*/, ""); print; exit }
' build.sh)
cli_version=$(sed -nE 's/.*\?\? "([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' Sources/token-bar/main.swift)

if [[ ! $build_version =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "Could not read the version from build.sh" >&2
    exit 1
fi
major=${BASH_REMATCH[1]}
minor=${BASH_REMATCH[2]}
patch=${BASH_REMATCH[3]}
if [[ $cli_version != "$build_version" ]]; then
    echo "Version mismatch: build.sh has $build_version, main.swift has $cli_version" >&2
    exit 1
fi

new_version="$major.$minor.$((patch + 1))"

BUILD_VERSION="$build_version" NEW_VERSION="$new_version" python3 <<'PY'
import os
from pathlib import Path

old = os.environ["BUILD_VERSION"]
new = os.environ["NEW_VERSION"]
expected_counts = {
    "build.sh": 2,  # short version and monotonically increasing bundle version
    "Sources/token-bar/main.swift": 1,
}
for name, expected in expected_counts.items():
    path = Path(name)
    text = path.read_text()
    actual = text.count(old)
    if actual != expected:
        raise SystemExit(f"Expected {expected} occurrences of {old!r} in {name}, found {actual}")
    path.write_text(text.replace(old, new))
PY

printf '%s\n' "$new_version"
