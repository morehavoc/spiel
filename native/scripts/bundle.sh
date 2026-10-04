#!/bin/bash
# Builds Spiel.app from the SPM executable.
#
# Bundling is not cosmetic here — it is required for correctness:
#   * TCC (microphone, Accessibility) keys off a bundle identifier. An unbundled
#     binary gets no stable identity, so permission grants do not stick.
#   * NSMicrophoneUsageDescription must exist or the mic prompt never appears and
#     capture fails silently.
#   * LSUIElement is what makes it a menu-bar app with no dock icon.
#
# Day-to-day dev builds: `scripts/bundle.sh` with no environment, as before.
# scripts/release.sh drives the official build through the same script with:
#   SPIEL_OFFICIAL_BUILD=1          compile with -DOFFICIAL_BUILD (the license gate)
#   SPIEL_GUMROAD_PRODUCT_ID=…      Info.plist SpielGumroadProductID
#   SPIEL_PURCHASE_URL=…            Info.plist SpielPurchaseURL
#   SPIEL_SKIP_SIGN=1               leave signing to the caller (Developer ID, inside-out)
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

SWIFT_FLAGS=()
[ "${SPIEL_OFFICIAL_BUILD:-}" = "1" ] && SWIFT_FLAGS=(-Xswiftc -DOFFICIAL_BUILD)

echo "==> swift build -c $CONFIG ${SWIFT_FLAGS[*]+${SWIFT_FLAGS[*]}}"
swift build -c "$CONFIG" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --product Spiel
swift build -c "$CONFIG" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --product spiel-tool

BIN_DIR="$(swift build -c "$CONFIG" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --show-bin-path)"
BIN="$BIN_DIR/Spiel"
TOOL="$BIN_DIR/spiel-tool"
[ -f "$BIN" ] || { echo "no binary at $BIN"; exit 1; }
[ -f "$TOOL" ] || { echo "no binary at $TOOL"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Spiel"
# Sparkle (auto-updates) is a dynamic framework linked with @rpath; an app bundle
# looks in Contents/Frameworks. Taken from SwiftPM's checksum-verified artifact, not
# the bin folder: a `--product` build does not copy it there. ditto keeps the
# framework's Versions/Current symlinks, which codesign requires.
SPARKLE_FW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$SPARKLE_FW" ] || { echo "no Sparkle.framework at $SPARKLE_FW (swift package resolve)"; exit 1; }
ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP/Contents/MacOS/Spiel" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Spiel"
fi
# The `spiel` command (menu → Install Command Line Tool… links ~/.local/bin/spiel
# here). Contents/Helpers, NOT Contents/MacOS: APFS is case-insensitive, so
# Contents/MacOS/spiel would be the app's own Contents/MacOS/Spiel.
cp "$TOOL" "$APP/Contents/Helpers/spiel"
# App icon (Finder, /Applications, Login Items, notifications — it is a menu-bar app,
# so there is no Dock tile). Regenerate with scripts/make-icon.py + iconutil.
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Shown by the standard About panel (Help → About Spiel).
cp "$ROOT/assets/Credits.html" "$APP/Contents/Resources/Credits.html"

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
    <key>NSHumanReadableCopyright</key><string>© 2025–2026 Christopher Moravec</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Spiel records your voice so it can transcribe it to text on this Mac.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Spiel transcribes your speech on-device.</string>
    <key>SUFeedURL</key>
    <string>https://github.com/morehavoc/spiel/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>Ubolp1jJStMcCdTrSYBTDesGE6c24ENds062AiWuHto=</string>
</dict>
</plist>
PLIST
# No SUEnableAutomaticChecks on purpose: without it Sparkle asks, once, whether to
# check automatically. The public key's private half: see RELEASING.md.
# plutil, not the heredoc, for values from the environment: it escapes & and <.
[ -n "${SPIEL_GUMROAD_PRODUCT_ID:-}" ] && plutil -insert SpielGumroadProductID -string "$SPIEL_GUMROAD_PRODUCT_ID" "$APP/Contents/Info.plist"
[ -n "${SPIEL_PURCHASE_URL:-}" ] && plutil -insert SpielPurchaseURL -string "$SPIEL_PURCHASE_URL" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

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
if [ "${SPIEL_SKIP_SIGN:-}" = "1" ]; then
  echo "==> not signed (SPIEL_SKIP_SIGN=1; the caller signs)"
  echo "==> built $APP ($VERSION build $BUILD)"
  exit 0
fi
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
