#!/bin/bash
# Builds Spiel.app from the SPM executable.
#
# Bundling is not cosmetic here — it is required for correctness:
#   * TCC (microphone, Accessibility) keys off a bundle identifier. An unbundled
#     binary gets no stable identity, so permission grants do not stick.
#   * NSMicrophoneUsageDescription must exist or the mic prompt never appears and
#     capture fails silently.
#   * LSUIElement is what makes it a menu-bar app with no dock icon.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Spiel.app"

cd "$ROOT"
# One source of truth for the version: Sources/SpielCore/Version.swift, which
# `spiel --version` also prints.
VERSION="$(sed -n 's/.*static let short = "\(.*\)".*/\1/p' Sources/SpielCore/Version.swift)"
BUILD="$(sed -n 's/.*static let build = "\(.*\)".*/\1/p' Sources/SpielCore/Version.swift)"
[ -n "$VERSION" ] && [ -n "$BUILD" ] || { echo "could not read the version from Sources/SpielCore/Version.swift"; exit 1; }

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product Spiel
swift build -c "$CONFIG" --product spiel-tool

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/Spiel"
TOOL="$BIN_DIR/spiel-tool"
[ -f "$BIN" ] || { echo "no binary at $BIN"; exit 1; }
[ -f "$TOOL" ] || { echo "no binary at $TOOL"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/Spiel"
# The `spiel` command (menu → Install Command Line Tool… links ~/.local/bin/spiel
# here). Contents/Helpers, NOT Contents/MacOS: APFS is case-insensitive, so
# Contents/MacOS/spiel would be the app's own Contents/MacOS/Spiel.
cp "$TOOL" "$APP/Contents/Helpers/spiel"
# App icon (Finder, /Applications, Login Items, notifications — it is a menu-bar app,
# so there is no Dock tile). Regenerate with scripts/make-icon.py + iconutil.
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Spiel</string>
    <key>CFBundleDisplayName</key><string>Spiel</string>
    <key>CFBundleIdentifier</key><string>com.morehavoc.spiel</string>
    <key>CFBundleExecutable</key><string>Spiel</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Spiel records your voice so it can transcribe it to text on this Mac.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Spiel transcribes your speech on-device.</string>
</dict>
</plist>
PLIST

# Signing identity matters for TCC, not just Gatekeeper. macOS keys an Accessibility /
# Microphone grant on the app's designated requirement. An AD-HOC signature has no
# certificate, so the requirement pins the code hash — which changes on EVERY rebuild,
# and the grant Christopher gave build 2 showed "ON" in System Settings while
# AXIsProcessTrusted() returned false for build 3 (2026-09-02). A self-signed
# certificate gives a stable requirement (`identifier "com.morehavoc.spiel" and
# certificate root = H"…"`), so the grant survives rebuilds. It is still not notarized:
# first launch still needs the xattr step or "Open Anyway".
#
# Identity: "Spiel Dev Signing" in ~/Library/Keychains/spiel-signing.keychain-db on
# jaws-mini (self-signed, 10-year, created 2026-09-02). Falls back to ad-hoc with a
# loud warning if the keychain is missing, because a silent fallback would reintroduce
# the rotating-identity bug while looking identical.
SIGN_KEYCHAIN="$HOME/Library/Keychains/spiel-signing.keychain-db"
SIGN_ID="Spiel Dev Signing"
if [ -f "$SIGN_KEYCHAIN" ] && security find-certificate -c "$SIGN_ID" "$SIGN_KEYCHAIN" >/dev/null 2>&1; then
  # Password comes from the environment; never hardcode it here. If it is unset we
  # try signing anyway — an unlocked keychain works fine, and a locked one fails
  # loudly at codesign rather than silently falling back to ad-hoc.
  if [ -n "${SPIEL_SIGN_KEYCHAIN_PASSWORD:-}" ]; then
    security unlock-keychain -p "$SPIEL_SIGN_KEYCHAIN_PASSWORD" "$SIGN_KEYCHAIN" 2>/dev/null || true
  else
    echo "NOTE: SPIEL_SIGN_KEYCHAIN_PASSWORD unset — assuming '$SIGN_KEYCHAIN' is already unlocked." >&2
  fi
  # The helper first, then the app (nested code must be signed before its container).
  codesign --force --sign "$SIGN_ID" --keychain "$SIGN_KEYCHAIN" "$APP/Contents/Helpers/spiel"
  codesign --force --deep --sign "$SIGN_ID" --keychain "$SIGN_KEYCHAIN" "$APP"
  echo "==> signed with '$SIGN_ID' (stable TCC identity)"
else
  echo "WARNING: '$SIGN_ID' not found — signing AD-HOC. Accessibility grants will NOT survive rebuilds." >&2
  codesign --force --sign - "$APP/Contents/Helpers/spiel" && codesign --force --deep --sign - "$APP" || echo "(codesign skipped)"
fi
codesign -d -r- "$APP" 2>&1 | grep designated

echo "==> built $APP ($VERSION build $BUILD; command-line tool at Contents/Helpers/spiel)"
echo "    open it with:  open '$APP'"
