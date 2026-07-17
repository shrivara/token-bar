#!/bin/bash
# Builds TokenBar.app from the Swift package.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=TokenBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>TokenBar</string>
	<key>CFBundleIdentifier</key>
	<string>com.shrivara.tokenbar</string>
	<key>CFBundleName</key>
	<string>TokenBar</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.7.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF

cp ".build/release/token-bar" "$APP/Contents/MacOS/TokenBar"
mkdir -p "$APP/Contents/Resources"
cp -R .build/release/*.bundle "$APP/Contents/Resources/"
echo "Built $APP"
