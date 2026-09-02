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

# Ad-hoc signature. Not notarized — first launch still needs a right-click > Open,
# or Privacy & Security > "Open Anyway".
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "(codesign skipped)"

echo "==> built $APP"
echo "    open it with:  open '$APP'"
