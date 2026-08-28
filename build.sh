#!/bin/bash
# Builds and ad-hoc signs TokenBar.app from the Swift package.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=TokenBar.app
EXECUTABLE="$APP/Contents/MacOS/TokenBar"
SIGN_IDENTITY=${TOKEN_BAR_SIGN_IDENTITY:--}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Token Bar</string>
	<key>CFBundleExecutable</key>
	<string>TokenBar</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.shrivara.tokenbar</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>TokenBar</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.8.35</string>
	<key>CFBundleVersion</key>
	<string>0.8.35</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSMultipleInstancesProhibited</key>
	<true/>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
EOF

cp ".build/release/token-bar" "$EXECUTABLE"
cp -R .build/release/*.bundle "$APP/Contents/Resources/"
cp "Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

sign_args=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    sign_args+=(--options runtime --timestamp)
fi
codesign "${sign_args[@]}" "$EXECUTABLE"
codesign "${sign_args[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Built $APP"
