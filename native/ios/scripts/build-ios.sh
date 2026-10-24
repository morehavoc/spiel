#!/bin/bash
# Build Spiel for iPhone. Usage:
#   native/ios/scripts/build-ios.sh sim        # simulator build (no signing)
#   native/ios/scripts/build-ios.sh device     # signed for the paired iPhone, installs with devicectl
# On jaws-mini SwiftPM's binary-artifact download hangs (curl works; RELEASING.md).
# This script curls the one binary artifact FluidAudio needs, serves it on
# localhost for the build only, and points a project-scoped SwiftPM mirror at it.
set -euo pipefail
IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
MODE="${1:-sim}"
NEMO=https://github.com/FluidInference/text-processing-rs/releases/download/v0.3.0/NemoTextProcessing.xcframework.zip
PORT=18978
MIR="$(mktemp -d)"; mkdir -p "$MIR/n"
curl -fsSL -o "$MIR/n/NemoTextProcessing.xcframework.zip" "$NEMO"
(cd "$MIR" && exec python3 -m http.server $PORT --bind 127.0.0.1 >/dev/null 2>&1) & SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$MIR"' EXIT
cd "$IOS_DIR"
xcodegen -q
CFG=SpielMobile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration
mkdir -p "$CFG"
cat > "$CFG/mirrors.json" <<JSON
{"object":[{"mirror":"http://127.0.0.1:$PORT/n/NemoTextProcessing.xcframework.zip","original":"$NEMO"}],"version":1}
JSON
DD="$IOS_DIR/DerivedData"
if [ "$MODE" = sim ]; then
  xcodebuild -project SpielMobile.xcodeproj -scheme SpielMobile -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" \
    -skipPackagePluginValidation ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
else
  xcodebuild -project SpielMobile.xcodeproj -scheme SpielMobile -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
    -skipPackagePluginValidation -allowProvisioningUpdates build
  APP="$DD/Build/Products/Release-iphoneos/Spiel.app"
  DEV=$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /physical/ && !/unavailable/ {print $3; exit}')
  [ -n "$DEV" ] || { echo "Built $APP, but no iPhone is reachable to install it on." >&2; exit 3; }
  xcrun devicectl device install app --device "$DEV" "$APP"
fi
