#!/usr/bin/env bash
# release.sh — build a universal (arm64 + x86_64) maccal.app, codesign it, and
# zip it as a release artifact. The version comes from the current git tag.
#
# Usage:
#   git tag v0.2.0          # tag the release commit first
#   ./release.sh            # → dist/maccal-<version>-macos-universal.zip (+ sha256)
#
# Then attach the zip to a GitHub release and put its sha256 in the Homebrew
# formula. Building both slices + lipo avoids needing full Xcode (xcbuild).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IDENTIFIER="kr.ikhoon.maccal"
VERSION="$(git describe --tags --always)"

if ! command -v swift >/dev/null 2>&1; then
  echo "release: swift not found (xcode-select --install)" >&2
  exit 127
fi

echo "release: building universal binary (arm64 + x86_64)…"
swift build -c release --arch arm64
swift build -c release --arch x86_64
ARM=".build/arm64-apple-macosx/release/maccal"
X86=".build/x86_64-apple-macosx/release/maccal"

DIST="dist"
APP="${DIST}/maccal.app"
MACOS_DIR="${APP}/Contents/MacOS"
rm -rf "$DIST"
mkdir -p "$MACOS_DIR"

echo "release: lipo → universal"
lipo -create -output "${MACOS_DIR}/maccal" "$ARM" "$X86"
cp "${SCRIPT_DIR}/Info.plist" "${APP}/Contents/Info.plist"

echo "release: codesigning ($IDENTIFIER)…"
codesign --sign - \
  --identifier "$IDENTIFIER" \
  --entitlements "${SCRIPT_DIR}/maccal.entitlements" \
  --force --options runtime \
  "$APP"

ZIP="${DIST}/maccal-${VERSION}-macos-universal.zip"
( cd "$DIST" && zip -qry "maccal-${VERSION}-macos-universal.zip" maccal.app )

echo
echo "release: artifact → ${ZIP}"
echo "release: archs    → $(lipo -archs "${MACOS_DIR}/maccal")"
echo "release: sha256   → $(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo
echo "Next:"
echo "  1. Create a GitHub release for ${VERSION} and attach ${ZIP}."
echo "  2. Put the sha256 (above) and the asset URL into the Homebrew formula."
