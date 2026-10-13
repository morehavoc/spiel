#!/bin/bash
# Builds the OFFICIAL Spiel: license gate compiled in, Developer ID signature,
# hardened runtime, notarized and stapled, in a DMG, with a signed Sparkle appcast.
# One-time setup: RELEASING.md.
#
#   scripts/release.sh             build, sign, notarize, DMG, appcast (nothing published)
#   scripts/release.sh --publish   the same, then tag v<version>, push the tag and create
#                                  the GitHub release with the DMG + appcast.xml
#   scripts/release.sh --ci        the GitHub Actions path (.github/workflows/release.yml): the
#                                  release and its tag already exist; notarizes with an App
#                                  Store Connect API key and uploads the DMG + appcast to it
#   scripts/release.sh --dry-run   everything that can run without Apple: signs with the
#                                  self-signed "Spiel Dev Signing" identity, skips
#                                  notarization and publishing, and reports (instead of
#                                  stopping on) what a real release would refuse.
#
# Environment (real release): SPIEL_GUMROAD_PRODUCT_ID, SPIEL_PURCHASE_URL.
# --ci also needs NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER and SPARKLE_KEY_FILE.
# Optional: SPIEL_SIGN_IDENTITY (a SHA-1 from `security find-identity`, if the keychain
# holds more than one Developer ID Application identity).
set -euo pipefail

DRY=0
PUBLISH=0
CI_MODE=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --publish) PUBLISH=1 ;;
    --ci) CI_MODE=1 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "release: unknown option $a" >&2; exit 1 ;;
  esac
done

die() { echo "release: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }
# A real release stops here; a dry run says what would have stopped it and carries on.
gate() { if [ "$DRY" = 1 ]; then echo "DRY RUN — a real release would stop here: $*" >&2; else die "$*"; fi; }

[ "$DRY" = 1 ] && [ "$PUBLISH" = 1 ] && die "--dry-run and --publish cannot be combined"
[ "$CI_MODE" = 1 ] && { [ "$DRY" = 1 ] || [ "$PUBLISH" = 1 ]; } && die "--ci cannot be combined with --dry-run or --publish"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(sed -n 's/.*static let short = "\(.*\)".*/\1/p' Sources/SpielCore/Version.swift)"
BUILD="$(sed -n 's/.*static let build = "\(.*\)".*/\1/p' Sources/SpielCore/Version.swift)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '$VERSION' in Version.swift is not x.y.z"
# Sparkle orders updates by CFBundleVersion: it must be a plain integer that grows.
[[ "$BUILD" =~ ^[0-9]+$ ]] || die "build '$BUILD' in Version.swift is not an integer"

TAG="v$VERSION"
REPO="morehavoc/spiel"
DMG_NAME="Spiel-$VERSION.dmg"
DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/$TAG/"
APP="$ROOT/build/Spiel.app"
DIST="$ROOT/dist/$VERSION"
DMG="$DIST/$DMG_NAME"
APPCAST="$DIST/appcast.xml"
SHARED="/Users/jaws/nexus/shared"
ENTITLEMENTS="$ROOT/scripts/Spiel.entitlements"
NOTARY_PROFILE="spiel-notary"
SPARKLE_KEY_FILE="${SPARKLE_KEY_FILE:-$HOME/.spiel-secrets/sparkle_ed25519_private.txt}"
# notarytool credentials: an App Store Connect API key (CI), else the keychain profile.
if [ -n "${NOTARY_KEY_PATH:-}" ]; then
  NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?NOTARY_KEY_ID}" --issuer "${NOTARY_ISSUER:?NOTARY_ISSUER}")
else
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
fi
SPARKLE_ACCOUNT="spiel"
# The signing tools, from Sparkle's release tarball. Same version as the Package.swift
# pin; the digest is GitHub's recorded asset digest for that file.
SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
SPARKLE_TOOLS="$HOME/Library/Caches/spiel-release/Sparkle-$SPARKLE_VERSION"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/spiel-release.XXXXXX")"
MOUNT=""
cleanup() {
  if [ -n "$MOUNT" ]; then
    hdiutil detach "$MOUNT" -quiet || echo "WARNING: could not detach $MOUNT — run: hdiutil detach '$MOUNT'" >&2
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "Spiel $VERSION (build $BUILD) — $([ "$DRY" = 1 ] && echo "DRY RUN" || echo "release")$([ "$PUBLISH" = 1 ] && echo " + publish")"

# ---------------------------------------------------------------------------------
if [ "$CI_MODE" = 1 ]; then
step "git: the release's tag $TAG is this commit"
[ "$(git rev-parse "refs/tags/$TAG^{commit}" 2>/dev/null)" = "$(git rev-parse HEAD)" ] \
  || die "tag $TAG is not the checked-out commit (Version.swift says $VERSION; tag the release v$VERSION)"
gh release view "$TAG" --repo "$REPO" >/dev/null || die "no GitHub release for $TAG"
echo "commit $(git rev-parse --short HEAD) = $TAG"
else
step "git: clean tree, unused tag $TAG"
if [ -n "$(git status --porcelain)" ]; then
  git status --short | head -20 >&2
  gate "the git tree is not clean"
fi
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && gate "tag $TAG already exists here — bump Sources/SpielCore/Version.swift"
if remote="$(git ls-remote --tags origin "refs/tags/$TAG")"; then
  [ -z "$remote" ] || gate "tag $TAG already exists on origin — bump Sources/SpielCore/Version.swift"
else
  gate "could not reach origin to check for tag $TAG"
fi
echo "commit $(git rev-parse --short HEAD), tag $TAG free"
fi

# ---------------------------------------------------------------------------------
step "Gumroad product"
if [ "$DRY" = 1 ]; then
  PRODUCT_ID="${SPIEL_GUMROAD_PRODUCT_ID:-dry-run-product-id}"
  PURCHASE_URL="${SPIEL_PURCHASE_URL:-https://example.invalid/spiel}"
else
  [ -n "${SPIEL_GUMROAD_PRODUCT_ID:-}" ] || die "refuse to build: SPIEL_GUMROAD_PRODUCT_ID is not set (RELEASING.md)"
  [ -n "${SPIEL_PURCHASE_URL:-}" ] || die "refuse to build: SPIEL_PURCHASE_URL is not set (RELEASING.md)"
  PRODUCT_ID="$SPIEL_GUMROAD_PRODUCT_ID"
  PURCHASE_URL="$SPIEL_PURCHASE_URL"
fi
echo "product id $PRODUCT_ID, purchase URL $PURCHASE_URL"

# ---------------------------------------------------------------------------------
step "signing identity"
KC=()
if [ "$DRY" = 1 ]; then
  SIGN_KEYCHAIN="$HOME/Library/Keychains/spiel-signing.keychain-db"
  IDENTITY="Spiel Dev Signing"
  security find-certificate -c "$IDENTITY" "$SIGN_KEYCHAIN" >/dev/null || die "'$IDENTITY' not found in $SIGN_KEYCHAIN (see bundle.sh)"
  if [ -n "${SPIEL_SIGN_KEYCHAIN_PASSWORD:-}" ]; then
    security unlock-keychain -p "$SPIEL_SIGN_KEYCHAIN_PASSWORD" "$SIGN_KEYCHAIN"
  fi
  KC=(--keychain "$SIGN_KEYCHAIN")
  gate "no Developer ID: signing with the self-signed '$IDENTITY' (Gatekeeper will reject this build)"
else
  ids="$(security find-identity -v -p codesigning | grep '"Developer ID Application: ' || true)"
  [ -n "$ids" ] || die "no \"Developer ID Application\" identity in the keychain (security find-identity -v -p codesigning). RELEASING.md step 1."
  if [ -n "${SPIEL_SIGN_IDENTITY:-}" ]; then
    echo "$ids" | grep -q "$SPIEL_SIGN_IDENTITY" || die "SPIEL_SIGN_IDENTITY=$SPIEL_SIGN_IDENTITY is not one of:"$'\n'"$ids"
    IDENTITY="$SPIEL_SIGN_IDENTITY"
  else
    [ "$(echo "$ids" | wc -l | tr -d ' ')" = 1 ] || die "more than one Developer ID Application identity; set SPIEL_SIGN_IDENTITY to one SHA-1:"$'\n'"$ids"
    IDENTITY="$(echo "$ids" | awk '{print $2}')"
  fi
  echo "$ids"
  step "notary credentials"
  out="$(xcrun notarytool history "${NOTARY_ARGS[@]}" 2>&1)" \
    || die "notarytool credentials do not work (RELEASING.md step 2):"$'\n'"$out"
  echo "ok"
fi

# ---------------------------------------------------------------------------------
step "Sparkle $SPARKLE_VERSION tools and the update signing key"
if [ ! -x "$SPARKLE_TOOLS/bin/generate_appcast" ]; then
  tarball="$WORK/Sparkle-$SPARKLE_VERSION.tar.xz"
  curl -fsSL --max-time 300 -o "$tarball" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  got="$(shasum -a 256 "$tarball" | awk '{print $1}')"
  [ "$got" = "$SPARKLE_SHA256" ] || die "Sparkle tarball digest $got, expected $SPARKLE_SHA256"
  rm -rf "$SPARKLE_TOOLS" && mkdir -p "$SPARKLE_TOOLS"
  tar -xf "$tarball" -C "$SPARKLE_TOOLS"
fi
# The key that signs the update must be the one whose public half ships in the app,
# or every installed copy rejects the update. Prefer the backup file (no keychain
# prompt); fall back to the login keychain.
if [ -f "$SPARKLE_KEY_FILE" ]; then
  KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
  SIGNING_PUB="$({ printf '302e020100300506032b657004220420' | xxd -r -p; base64 -d < "$SPARKLE_KEY_FILE"; } \
    | openssl pkey -inform DER -pubout -outform DER | tail -c 32 | base64)"
else
  KEY_ARGS=(--account "$SPARKLE_ACCOUNT")
  SIGNING_PUB="$("$SPARKLE_TOOLS/bin/generate_keys" --account "$SPARKLE_ACCOUNT" -p)"
fi
PLIST_PUB="$(grep -A1 '<key>SUPublicEDKey</key>' scripts/bundle.sh | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p')"
[ -n "$SIGNING_PUB" ] && [ "$SIGNING_PUB" = "$PLIST_PUB" ] \
  || die "the Sparkle signing key (public $SIGNING_PUB) is not the one in bundle.sh's SUPublicEDKey ($PLIST_PUB)"
echo "signing key matches SUPublicEDKey $PLIST_PUB (${KEY_ARGS[0]} ${KEY_ARGS[1]})"

# ---------------------------------------------------------------------------------
step "build (OFFICIAL_BUILD)"
SPIEL_OFFICIAL_BUILD=1 SPIEL_SKIP_SIGN=1 SPIEL_GUMROAD_PRODUCT_ID="$PRODUCT_ID" SPIEL_PURCHASE_URL="$PURCHASE_URL" \
  "$ROOT/scripts/bundle.sh" release
v="$("$APP/Contents/Helpers/spiel" --version)"
[[ "$v" == *", official)"* ]] || die "the build is not an official build: '$v'"
[ "$(plutil -extract SpielGumroadProductID raw "$APP/Contents/Info.plist")" = "$PRODUCT_ID" ] || die "Info.plist has the wrong product id"
echo "$v"

# ---------------------------------------------------------------------------------
step "sign, inside-out (hardened runtime, secure timestamp)"
FW="$APP/Contents/Frameworks/Sparkle.framework"
FWV="$FW/Versions/B"
[ -d "$FWV/XPCServices/Installer.xpc" ] && [ -d "$FWV/XPCServices/Downloader.xpc" ] && [ -f "$FWV/Autoupdate" ] && [ -d "$FWV/Updater.app" ] \
  || die "Sparkle.framework layout changed (expected Versions/B/{XPCServices/Installer.xpc,XPCServices/Downloader.xpc,Autoupdate,Updater.app}); update the signing list"
sign() { codesign --force --options runtime --timestamp ${KC[@]+"${KC[@]}"} --sign "$IDENTITY" "$@"; }
# Sparkle's documented order for a non-sandboxed app; Downloader.xpc keeps its own
# entitlements (network client).
sign "$FWV/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$FWV/XPCServices/Downloader.xpc"
sign "$FWV/Autoupdate"
sign "$FWV/Updater.app"
sign "$FW"
sign "$APP/Contents/Helpers/spiel"
APP_ENTITLEMENTS="$ENTITLEMENTS"
if [ "$DRY" = 1 ]; then
  # A self-signed certificate has no Team ID, and hardened-runtime library validation
  # refuses any framework without the process's Team ID: Sparkle.framework would not
  # load (dyld: "Library not loaded … code signature … not valid"). Dry run only; a
  # Developer ID signs app and framework with one team and keeps validation on.
  APP_ENTITLEMENTS="$WORK/dry-run.entitlements"
  # (Written whole: plutil -insert reads the dotted key as a key path.)
  sed 's|</dict>|    <key>com.apple.security.cs.disable-library-validation</key>\
    <true/>\
</dict>|' "$ENTITLEMENTS" > "$APP_ENTITLEMENTS"
  plutil -lint "$APP_ENTITLEMENTS" >/dev/null
  echo "DRY RUN: + com.apple.security.cs.disable-library-validation (no Team ID); a real release signs with exactly $ENTITLEMENTS"
fi
sign --entitlements "$APP_ENTITLEMENTS" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.device.audio-input" \
  || die "the app is missing the audio-input entitlement"
if [ "$DRY" = 0 ] && codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "disable-library-validation"; then
  die "a release build must keep library validation on"
fi
codesign -d --verbose=2 "$APP" 2>&1 | grep -E "^(Authority|Timestamp|TeamIdentifier|Runtime Version|CodeDirectory)" || true

notarize() {
  local file="$1" out status id
  out="$(xcrun notarytool submit "$file" "${NOTARY_ARGS[@]}" --wait --output-format json)" \
    || die "notarytool submit failed for $file"
  status="$(plutil -extract status raw - <<<"$out")"
  id="$(plutil -extract id raw - <<<"$out")"
  echo "notarization $id: $status"
  if [ "$status" != "Accepted" ]; then
    xcrun notarytool log "$id" "${NOTARY_ARGS[@]}" >&2 || true
    die "notarization of $(basename "$file") was $status"
  fi
}

# ---------------------------------------------------------------------------------
# The app is notarized and stapled on its own first, so the copy inside the DMG
# (and the one Sparkle unpacks on update) carries its ticket offline.
if [ "$DRY" = 1 ]; then
  step "notarize app: SKIPPED (dry run)"
else
  step "notarize + staple the app"
  ditto -c -k --keepParent "$APP" "$WORK/Spiel.zip"
  notarize "$WORK/Spiel.zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

# ---------------------------------------------------------------------------------
step "DMG"
mkdir -p "$DIST" "$WORK/dmg"
rm -f "$DMG" "$APPCAST"
ditto "$APP" "$WORK/dmg/Spiel.app"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -volname "Spiel" -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --timestamp ${KC[@]+"${KC[@]}"} --sign "$IDENTITY" "$DMG"
if [ "$DRY" = 1 ]; then
  step "notarize DMG: SKIPPED (dry run)"
else
  step "notarize + staple the DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

# ---------------------------------------------------------------------------------
step "checks"
codesign --verify --strict --deep --verbose=2 "$APP"
codesign --verify --strict --verbose=2 "$DMG"
MOUNT="$WORK/mnt"
mkdir -p "$MOUNT"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" -quiet
[ -L "$MOUNT/Applications" ] || die "the DMG has no /Applications link"
codesign --verify --strict --deep --verbose=2 "$MOUNT/Spiel.app"
[ "$(plutil -extract CFBundleVersion raw "$MOUNT/Spiel.app/Contents/Info.plist")" = "$BUILD" ] || die "the DMG holds a different build"
spctl_ok=1
/usr/sbin/spctl -a -vv -t execute "$MOUNT/Spiel.app" || spctl_ok=0
/usr/sbin/spctl -a -vv -t open --context context:primary-signature "$DMG" || spctl_ok=0
hdiutil detach "$MOUNT" -quiet
MOUNT=""
[ "$spctl_ok" = 1 ] || gate "Gatekeeper (spctl) rejects the app or the DMG"

# ---------------------------------------------------------------------------------
step "appcast"
mkdir -p "$WORK/appcast"
cp "$DMG" "$WORK/appcast/"
"$SPARKLE_TOOLS/bin/generate_appcast" "${KEY_ARGS[@]}" --download-url-prefix "$DOWNLOAD_PREFIX" -o "$APPCAST" "$WORK/appcast"
grep -q "url=\"$DOWNLOAD_PREFIX$DMG_NAME\"" "$APPCAST" || die "appcast.xml does not point at $DOWNLOAD_PREFIX$DMG_NAME"
grep -q "<sparkle:version>$BUILD</sparkle:version>" "$APPCAST" || die "appcast.xml does not carry build $BUILD"
sig="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$APPCAST" | head -1)"
[ -n "$sig" ] || die "appcast.xml has no EdDSA signature"
"$SPARKLE_TOOLS/bin/sign_update" --verify "${KEY_ARGS[@]}" "$DMG" "$sig" || die "the appcast's signature does not verify against the DMG"
echo "appcast: $APPCAST (signature verified)"

# ---------------------------------------------------------------------------------
if [ -d "$SHARED" ]; then
step "copy to shared/"
SHARED_NAME="$DMG_NAME"
[ "$DRY" = 1 ] && SHARED_NAME="Spiel-$VERSION-dryrun.dmg"
cp "$DMG" "$SHARED/$SHARED_NAME"
[ "$(shasum -a 256 < "$DMG")" = "$(shasum -a 256 < "$SHARED/$SHARED_NAME")" ] || die "the copy in $SHARED differs from $DMG"
echo "$SHARED/$SHARED_NAME"
fi

# ---------------------------------------------------------------------------------
if [ "$CI_MODE" = 1 ]; then
  step "upload to the $TAG release"
  gh release upload "$TAG" "$DMG" "$APPCAST" --repo "$REPO" --clobber
elif [ "$PUBLISH" = 1 ]; then
  step "publish $TAG"
  git tag -a "$TAG" -m "Spiel $VERSION (build $BUILD)"
  git push origin "$TAG"
  gh release create "$TAG" "$DMG" "$APPCAST" --repo "$REPO" --verify-tag --latest \
    --title "Spiel $VERSION" --notes "Spiel $VERSION (build $BUILD)"
else
  step "not published (run with --publish to tag $TAG and create the GitHub release)"
fi

echo
echo "DMG:     $DMG"
echo "appcast: $APPCAST"
[ "$DRY" = 1 ] && echo "DRY RUN finished. Signed with '$IDENTITY'; not notarized; not published."
exit 0
