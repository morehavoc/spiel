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
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product Spiel

BIN="$(swift build -c "$CONFIG" --show-bin-path)/Spiel"
[ -f "$BIN" ] || { echo "no binary at $BIN"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Spiel"

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
    <key>CFBundleShortVersionString</key><string>2.0.0</string>
    <key>CFBundleVersion</key><string>2</string>
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
  security unlock-keychain -p spielkc "$SIGN_KEYCHAIN" 2>/dev/null || true
  codesign --force --deep --sign "$SIGN_ID" --keychain "$SIGN_KEYCHAIN" "$APP"
  echo "==> signed with '$SIGN_ID' (stable TCC identity)"
else
  echo "WARNING: '$SIGN_ID' not found — signing AD-HOC. Accessibility grants will NOT survive rebuilds." >&2
  codesign --force --deep --sign - "$APP" 2>/dev/null || echo "(codesign skipped)"
fi
codesign -d -r- "$APP" 2>&1 | grep designated

echo "==> built $APP"
echo "    open it with:  open '$APP'"
