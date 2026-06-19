#!/usr/bin/env bash
# install.sh — build maccal, package it as a .app bundle, codesign it with a
# stable identifier, and symlink the bundle's executable (plus shell
# completions) onto PATH.
#
# Why a .app bundle: macOS TCC grants and persists Calendar access PER APP
# BUNDLE. A bare CLI executable can't get its own "Calendar" row in System
# Settings — it can only inherit the host terminal app's grant. Packaging
# maccal.app gives it an independent, stable Calendar permission keyed on the
# bundle identifier (so `tccutil reset Calendar kr.ikhoon.maccal` works and the
# grant survives rebuilds).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IDENTIFIER="kr.ikhoon.maccal"

# === Prerequisites ===
if ! command -v swift >/dev/null 2>&1; then
  echo "maccal: swift not found. Install Xcode or the Command Line Tools:"
  echo "  xcode-select --install"
  exit 127
fi

# === Build ===
echo "maccal: compiling binary (swift build -c release)..."
swift build -c release

SRC="${SCRIPT_DIR}/.build/release/maccal"
if [[ ! -x "$SRC" ]]; then
  echo "maccal: build did not produce $SRC" >&2
  exit 1
fi

# === Assemble the .app bundle ===
APP_DIR="${HOME}/.local/lib/maccal.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
echo "maccal: packaging ${APP_DIR}..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$SRC" "${MACOS_DIR}/maccal"
cp "${SCRIPT_DIR}/Info.plist" "${APP_DIR}/Contents/Info.plist"

# === Codesign the bundle (before it is ever run) ===
# A STABLE --identifier makes TCC's designated requirement identifier-based, so
# the Calendar grant persists across rebuilds. --entitlements declares the
# calendars personal-information class.
echo "maccal: codesigning ($IDENTIFIER)..."
codesign --sign - \
  --identifier "$IDENTIFIER" \
  --entitlements "${SCRIPT_DIR}/maccal.entitlements" \
  --force --options runtime \
  "$APP_DIR"

# === Symlink the bundle's executable ===
BIN_DIR="${HOME}/.local/bin"
DEST="${BIN_DIR}/maccal"

mkdir -p "$BIN_DIR"
if [[ -L "$DEST" || -e "$DEST" ]]; then
  echo "maccal: $DEST already exists; replacing"
  rm -f "$DEST"
fi
ln -s "${MACOS_DIR}/maccal" "$DEST"
echo "maccal: installed → $DEST → ${MACOS_DIR}/maccal"

# Warn if ~/.local/bin isn't on PATH — otherwise `maccal` won't be found.
case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;; # already on PATH
  *)
    echo "maccal: NOTE — ${BIN_DIR} is not on your PATH. Add this to your shell rc:"
    echo "           export PATH=\"${BIN_DIR}:\$PATH\""
    ;;
esac

# === Shell completions (generated from the binary by swift-argument-parser) ===
BIN="${MACOS_DIR}/maccal"

# Delegate to the binary so a binary-only install (no install.sh) gets the same
# behavior via `maccal completions --install` — single source of truth.
"$BIN" completions --shell zsh --install || true
"$BIN" completions --shell bash --install || true

cat <<EOF

Verify:
  which maccal
  maccal --help

The first command that touches the calendar will prompt for Calendar access
(shown as "maccal"). Click Allow — or grant it in System Settings → Privacy &
Security → Calendars (enable maccal). No Full Disk Access and no OAuth are
required — maccal reads the local calendar store that macOS already syncs.
EOF
