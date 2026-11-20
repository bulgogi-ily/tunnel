#!/usr/bin/env bash
# build.sh — compile Tunnel.app into ~/Applications (needs Xcode Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/Tunnel.app"
BUILD=$(mktemp -d); trap 'rm -rf "$BUILD"' EXIT

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# -swift-version 5: Command Line Tools lack the SwiftUI macro plugin, so the app avoids @State.
swiftc -O -swift-version 5 -parse-as-library Tunnel.swift -o "$APP/Contents/MacOS/Tunnel"

swiftc -swift-version 5 Icon.swift -o "$BUILD/icongen"
"$BUILD/icongen" "$BUILD/icon.png"
mkdir "$BUILD/T.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon.png" --out "$BUILD/T.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$BUILD/icon.png" --out "$BUILD/T.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD/T.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Tunnel</string>
  <key>CFBundleDisplayName</key><string>Tunnel</string>
  <key>CFBundleIdentifier</key><string>local.tunnel.gui</string>
  <key>CFBundleExecutable</key><string>Tunnel</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force --deep -s - "$APP"
echo "Built $APP"
