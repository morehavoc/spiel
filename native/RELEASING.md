# Releasing Spiel

The official build is the same source compiled with `-DOFFICIAL_BUILD` (14-day trial,
then a Gumroad license), signed with a Developer ID, notarized, shipped as a DMG on
GitHub Releases, and updated by Sparkle. A plain source build has no license gate.

## One-time setup

1. **Developer ID certificate.** developer.apple.com → Certificates → + → Developer ID
   Application (account holder only). Make the CSR in Keychain Access, install the
   certificate into the login keychain, then check:

       security find-identity -v -p codesigning | grep "Developer ID Application"

2. **Notary credentials.** Make an app-specific password at account.apple.com, then:

       xcrun notarytool store-credentials spiel-notary \
         --apple-id <apple id> --team-id <team id> --password <app-specific password>

3. **Gumroad product.** On the product, turn on "Generate a unique license key per
   sale". The product ID is shown there. Export it with the product page URL:

       export SPIEL_GUMROAD_PRODUCT_ID=<product id>
       export SPIEL_PURCHASE_URL=https://<you>.gumroad.com/l/<product>

   The release script refuses to build without both. Activation allows 2 Macs per key
   (Gumroad's `uses` count). To free a seat, decrement uses or disable the key in
   Gumroad; a disabled, refunded or charged-back key stops working after two weekly
   checks.

4. **Sparkle update key.** Already generated on jaws-mini (2026-10-03):
   - private key: login keychain, account `spiel`
     (`generate_keys --account spiel -p` prints the public key)
   - backup: `~/.spiel-secrets/sparkle_ed25519_private.txt` (0600, dir 0700)
   - public key: `SUPublicEDKey` in `scripts/bundle.sh`

   Copy the backup into 1Password. Never commit it, never put it on the NAS. Installed
   copies accept only updates signed with this key. Restore on another Mac with
   `generate_keys --account spiel -f <file>`. The tools are in
   `~/Library/Caches/spiel-release/Sparkle-<version>/bin` after the first release run.

## Release

1. Bump `Sources/SpielCore/Version.swift` (`short` and `build`; build must grow).
2. Commit. The tree must be clean.
3. Build, sign, notarize, DMG, appcast:

       native/scripts/release.sh

   Output: `native/dist/<version>/Spiel-<version>.dmg` and `appcast.xml`, plus a copy
   of the DMG in `/Users/jaws/nexus/shared/`.
4. Publish (tags `v<version>`, pushes the tag, creates the GitHub release with the DMG
   and `appcast.xml`):

       native/scripts/release.sh --publish

   Sparkle reads `releases/latest/download/appcast.xml`, so the newest non-prerelease
   release is the one every copy updates to.

`native/scripts/release.sh --dry-run` runs the whole pipeline with the self-signed
"Spiel Dev Signing" identity, skips notarization and publishing, and lists what a real
release would have refused. Its DMG goes to `shared/Spiel-<version>-dryrun.dmg`.

## Building on jaws-mini

SwiftPM's binary-artifact download hangs on this Mac (curl works). If a fresh checkout
stalls at `Downloading binary artifact`, fetch the zip with curl and serve it to a
SwiftPM mirror on localhost, or copy `.build/artifacts` from a checkout that has it.
Delete `.swiftpm/configuration/mirrors.json` afterwards.
