#!/usr/bin/env bash
# Build ClaudePet.app (needs only the Xcode command line tools) and install it to ~/Applications.
#   ./build.sh            build + install + launch
set -euo pipefail
cd "$(dirname "$0")"
APP=build/ClaudePet.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/ClaudePet" main.swift
cp Resources/*.png "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ClaudePet</string>
  <key>CFBundleIdentifier</key><string>io.github.kirigirihitomi.claude-pixel-pet</string>
  <key>CFBundleExecutable</key><string>ClaudePet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign -s - --force "$APP" >/dev/null
mkdir -p ~/Applications && rm -rf ~/Applications/ClaudePet.app && cp -R "$APP" ~/Applications/
pkill -x ClaudePet && while pgrep -x ClaudePet >/dev/null; do sleep 0.2; done || true
open ~/Applications/ClaudePet.app
echo "installed ~/Applications/ClaudePet.app"
