#!/bin/bash
# Verifies the structure and code seal of a built TokenBar.app.
set -euo pipefail

APP=${1:-TokenBar.app}
PLIST="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/TokenBar"
RESOURCES="$APP/Contents/Resources"

fail() {
    echo "verify-app: $*" >&2
    exit 1
}

[[ -d "$APP" ]] || fail "missing app bundle: $APP"
[[ -x "$EXECUTABLE" ]] || fail "missing executable: $EXECUTABLE"
[[ -s "$RESOURCES/AppIcon.icns" ]] || fail "missing app icon"
find "$RESOURCES" -name model-pricing.json -type f -print -quit | grep -q . || fail "missing pricing catalog"
find "$RESOURCES" -name anthropic.svg -type f -print -quit | grep -q . || fail "missing provider resources"

plutil -lint "$PLIST" >/dev/null
[[ $(plutil -extract CFBundleIdentifier raw "$PLIST") == com.shrivara.tokenbar ]] || fail "wrong bundle identifier"
[[ $(plutil -extract CFBundleIconFile raw "$PLIST") == AppIcon ]] || fail "wrong icon name"
[[ $(plutil -extract LSMinimumSystemVersion raw "$PLIST") == 14.0 ]] || fail "wrong minimum macOS version"
[[ $(plutil -extract LSUIElement raw "$PLIST") == true ]] || fail "app must be an LSUIElement"
[[ $(plutil -extract LSMultipleInstancesProhibited raw "$PLIST") == true ]] || fail "multiple instances must be prohibited"

short_version=$(plutil -extract CFBundleShortVersionString raw "$PLIST")
bundle_version=$(plutil -extract CFBundleVersion raw "$PLIST")
[[ $short_version == "$bundle_version" ]] || fail "short and bundle versions differ"
[[ $short_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid version: $short_version"

codesign --verify --deep --strict --verbose=2 "$APP"
echo "Verified $APP ($short_version)"
