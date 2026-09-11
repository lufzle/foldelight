#!/bin/bash
# Copyright (C) 2026 Dario Farzati
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PWD/dist/foldelight.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
# Replace the inode rather than overwrite pages mapped by a running build.
# In-place writes can terminate that process with CODESIGNING / Invalid Page.
INSTALL_BINARY="$(mktemp "$APP_DIR/Contents/MacOS/.foldelight.XXXXXX")"
trap 'rm -f "$INSTALL_BINARY"' EXIT
cp "$BIN_DIR/foldelight" "$INSTALL_BINARY"
chmod 755 "$INSTALL_BINARY"
mv -f "$INSTALL_BINARY" "$APP_DIR/Contents/MacOS/foldelight"
cp -R "$BIN_DIR/foldelight_foldelight.bundle" "$APP_DIR/Contents/Resources/"
cp LICENSE "$APP_DIR/Contents/Resources/LICENSE"
swift Tools/generate-icon.swift "$PWD/dist/foldelight.iconset"
iconutil -c icns "$PWD/dist/foldelight.iconset" -o "$APP_DIR/Contents/Resources/foldelight.icns"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>foldelight</string>
<key>CFBundleIdentifier</key><string>com.lufzle.foldelight</string>
<key>CFBundleName</key><string>foldelight</string>
<key>CFBundleDisplayName</key><string>foldelight</string>
<key>CFBundleIconFile</key><string>foldelight</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Dario Farzati. Licensed under AGPL-3.0-only.</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>foldelight uses a live desktop feed for its lid-controlled effect. Live frames stay in memory. Videos are saved locally only when you start a diagnostic recording.</string>
</dict></plist>
PLIST
SIGNING_IDENTITY="${FOLDELIGHT_SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk '/"Apple Development:|"Developer ID Application:/ { print $2; exit }')"
fi
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY="-"
    printf 'Warning: no development identity found. Ad-hoc rebuilds require renewed Screen Recording permission.\n' >&2
fi
codesign --force --sign "$SIGNING_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
