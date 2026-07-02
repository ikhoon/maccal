#!/usr/bin/env bash
# package.sh — build a universal (arm64 + x86_64) maccalbar.app menu-bar app,
# codesign it, and zip it as a release artifact.
#
# maccalbar is a menu-bar (LSUIElement) app that runs `maccal sync` manually or
# on a launchd schedule. It shells out to the installed `maccal` CLI for the
# background job, so install maccal first (`brew install ikhoon/tap/maccal`).
#
# Usage:
#   ./package.sh            # → dist/maccalbar-<version>-macos-universal.zip (+ sha256)
#
# A stable ad-hoc identifier (kr.ikhoon.maccalbar) keeps the macOS Calendar TCC
# grant across rebuilds. Building both slices + lipo avoids needing full Xcode.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IDENTIFIER="kr.ikhoon.maccalbar"
VERSION="$(git describe --tags --always)"

if ! command -v swift >/dev/null 2>&1; then
  echo "package: swift not found (xcode-select --install)" >&2
  exit 127
fi

echo "package: building universal binary (arm64 + x86_64)…"
swift build -c release --arch arm64 --product maccalbar
swift build -c release --arch x86_64 --product maccalbar
ARM=".build/arm64-apple-macosx/release/maccalbar"
X86=".build/x86_64-apple-macosx/release/maccalbar"

DIST="dist"
APP="${DIST}/maccalbar.app"
MACOS_DIR="${APP}/Contents/MacOS"
rm -rf "$APP"
mkdir -p "$MACOS_DIR"

echo "package: lipo → universal"
lipo -create -output "${MACOS_DIR}/maccalbar" "$ARM" "$X86"

# A menu-bar app needs a real bundle Info.plist (LSUIElement hides the Dock icon
# and the app row; the usage keys drive the Calendar prompt).
cat > "${APP}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${IDENTIFIER}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>maccalbar</string>
  <key>CFBundleDisplayName</key><string>maccal sync</string>
  <key>CFBundleExecutable</key><string>maccalbar</string>
  <key>CFBundleShortVersionString</key><string>${VERSION#v}</string>
  <key>CFBundleVersion</key><string>${VERSION#v}</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>maccal syncs events between your calendars.</string>
  <key>NSCalendarsUsageDescription</key><string>maccal syncs events between your calendars.</string>
</dict>
</plist>
EOF

echo "package: codesigning ($IDENTIFIER)…"
codesign --sign - \
  --identifier "$IDENTIFIER" \
  --entitlements "${SCRIPT_DIR}/maccal.entitlements" \
  --force --options runtime \
  "$APP"

ZIP="${DIST}/maccalbar-${VERSION}-macos-universal.zip"
( cd "$DIST" && rm -f "maccalbar-${VERSION}-macos-universal.zip" \
  && ditto -c -k --sequesterRsrc --keepParent maccalbar.app "maccalbar-${VERSION}-macos-universal.zip" )

echo
echo "package: artifact → ${ZIP}"
echo "package: archs    → $(lipo -archs "${MACOS_DIR}/maccalbar")"
echo "package: sha256   → $(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo
echo "Next:"
echo "  1. Unzip and drag maccalbar.app to /Applications."
echo "  2. Launch it — a calendar icon appears in the menu bar."
echo "  3. Pick Sources + Target, then toggle 'Run in background'."
