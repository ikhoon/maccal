#!/usr/bin/env bash
# package.sh — build a universal (arm64 + x86_64) maccal.app menu-bar app,
# codesign it, and zip it as a release artifact.
#
# This is the menu-bar companion to the maccal CLI: a menu-bar (LSUIElement) app
# that runs `maccal sync` manually or on a launchd schedule. It shells out to the
# installed `maccal` CLI for the background job, so install maccal first
# (`brew install ikhoon/tap/maccal`).
#
# The bundle is named maccal.app and shows as "maccal" in the menu bar, but keeps
# its own bundle identifier (kr.ikhoon.maccalbar) — distinct from the CLI bundle —
# so its macOS Calendar (TCC) grant is tracked separately and survives rebuilds.
# CFBundleExecutable stays "maccalbar" (the built product); only the name shown
# to the user is "maccal". Building both slices + lipo avoids needing full Xcode.
#
# Usage:
#   ./package.sh            # → dist/maccal-menubar-<version>-macos-universal.zip (+ sha256)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IDENTIFIER="kr.ikhoon.maccalbar"
VERSION="$(git describe --tags --always)"
# Code-signing identity. Default "-" = ad-hoc (release / brew artifacts stay
# cert-free and reproducible). Set MACCAL_SIGN_ID to a keychain codesigning
# identity (e.g. a self-signed "ikhoon-dev") for LOCAL installs so the Calendar
# (TCC) grant survives rebuilds — ad-hoc resigns with a new cdhash each build and
# forces a re-`maccal auth` every time. Notarization is a separate, later step.
SIGN_ID="${MACCAL_SIGN_ID:--}"
INSTALL=0
[ "${1:-}" = "--install" ] && INSTALL=1

if ! command -v swift >/dev/null 2>&1; then
  echo "package: swift not found (xcode-select --install)" >&2
  exit 127
fi

echo "package: building universal binaries (arm64 + x86_64)…"
swift build -c release --arch arm64 --product maccalbar
swift build -c release --arch x86_64 --product maccalbar
swift build -c release --arch arm64 --product maccal
swift build -c release --arch x86_64 --product maccal
ARM=".build/arm64-apple-macosx/release/maccalbar"
X86=".build/x86_64-apple-macosx/release/maccalbar"
ARM_CLI=".build/arm64-apple-macosx/release/maccal"
X86_CLI=".build/x86_64-apple-macosx/release/maccal"

DIST="dist"
APP="${DIST}/maccal.app"
MACOS_DIR="${APP}/Contents/MacOS"
RES_DIR="${APP}/Contents/Resources"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RES_DIR"
# App icon — the same sync-ring + calendar mark as the menu-bar/tray glyph.
[ -f "${SCRIPT_DIR}/assets/AppIcon.icns" ] && cp "${SCRIPT_DIR}/assets/AppIcon.icns" "${RES_DIR}/AppIcon.icns"

echo "package: lipo → universal"
lipo -create -output "${MACOS_DIR}/maccalbar" "$ARM" "$X86"
# Bundle the CLI too, so the app is self-contained (background sync shells out
# to this copy — see resolveMaccalPath — rather than a separate brew install).
lipo -create -output "${MACOS_DIR}/maccal" "$ARM_CLI" "$X86_CLI"

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
  <key>CFBundleName</key><string>maccal</string>
  <key>CFBundleDisplayName</key><string>maccal</string>
  <key>CFBundleExecutable</key><string>maccalbar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${VERSION#v}</string>
  <key>CFBundleVersion</key><string>${VERSION#v}</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>maccal syncs events between your calendars.</string>
  <key>NSCalendarsUsageDescription</key><string>maccal syncs events between your calendars.</string>
</dict>
</plist>
EOF

echo "package: codesigning bundled CLI + app… (identity: ${SIGN_ID})"
# Sign the nested CLI FIRST (nested code must be signed before its container),
# and with the APP's identifier so TCC treats it as the same entity — the CLI
# then shares the app's Calendar grant instead of prompting, which it cannot do
# as a background launchd job. A distinct identifier here leaves it at TCC
# auth_value 0 and EventKit hangs waiting for a prompt that never appears.
codesign --sign "$SIGN_ID" \
  --identifier "$IDENTIFIER" \
  --entitlements "${SCRIPT_DIR}/maccal.entitlements" \
  --force --options runtime \
  "${MACOS_DIR}/maccal"
codesign --sign "$SIGN_ID" \
  --identifier "$IDENTIFIER" \
  --entitlements "${SCRIPT_DIR}/maccal.entitlements" \
  --force --options runtime \
  "$APP"

ZIP="${DIST}/maccal-menubar-${VERSION}-macos-universal.zip"
( cd "$DIST" && rm -f "maccal-menubar-${VERSION}-macos-universal.zip" \
  && ditto -c -k --sequesterRsrc --keepParent maccal.app "maccal-menubar-${VERSION}-macos-universal.zip" )

echo
echo "package: artifact → ${ZIP}"
echo "package: archs    → $(lipo -archs "${MACOS_DIR}/maccalbar")"
echo "package: sha256   → $(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo
if [ "$INSTALL" = "1" ]; then
  echo "package: installing to /Applications…"
  osascript -e 'tell application "maccal" to quit' 2>/dev/null || true
  pkill -x maccalbar 2>/dev/null || true
  rm -rf /Applications/maccal.app
  ditto "$APP" /Applications/maccal.app
  # Expose the bundled (signed) CLI on PATH at ~/.local/bin for testing the dev
  # build — kept separate from any brew-installed release under the brew prefix.
  # Symlink (not copy) so the CLI keeps the app's signature/TCC grant.
  BINDIR="${HOME}/.local/bin"
  mkdir -p "$BINDIR"
  ln -sf /Applications/maccal.app/Contents/MacOS/maccal "$BINDIR/maccal"
  open /Applications/maccal.app
  echo "package: installed → /Applications/maccal.app (v${VERSION#v}), symlinked ${BINDIR}/maccal, relaunched."
else
  echo "Next:"
  echo "  • Install + relaunch locally:  ./package.sh --install"
  echo "  • Or unzip ${ZIP} and drag maccal.app to /Applications."
  echo "  • Then open Settings…, pick Sources + Target — background sync starts automatically."
fi
