# Releasing Spiel

The official build is the same source compiled with `-DOFFICIAL_BUILD` (14-day trial,
then a Gumroad license), signed with a Developer ID, notarized, shipped as a DMG on
GitHub Releases, and updated by Sparkle. A plain source build has no license gate.

## Releases run on GitHub Actions

`.github/workflows/release.yml` does the whole release when a GitHub release is
published: selftest, build with `-DOFFICIAL_BUILD`, Developer ID signing in a throwaway
keychain, notarization with an App Store Connect API key, DMG, Sparkle appcast, and
both files attached to the release. Nobody signs on a Mac.

### One-time setup: repository secrets

The four Apple secrets are the same values Margins uses (margins-v2 `docs/releasing.md`
steps 1–2: the Developer ID `.p12` and the `AuthKey_<id>.p8`).

- `APPLE_CERTIFICATE`: `base64 -i margins-developer-id.p12`
- `APPLE_CERTIFICATE_PASSWORD`: its export password
- `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`: the App Store Connect key's ids
- `APPLE_API_KEY`: `base64 -i AuthKey_<id>.p8`
- `SPARKLE_PRIVATE_KEY`: the Sparkle EdDSA private key (below)
- `GUMROAD_PRODUCT_ID`: the product's id (Gumroad → product → License key block; turn on
  "Generate a unique license key per sale")
- `SPIEL_PURCHASE_URL`: the product page

If either Gumroad secret is empty the release fails and nothing is built. A build
without the license gate takes the repository variable `SPIEL_UNLICENSED=true`
(Settings → Secrets and variables → Actions → Variables).

Activation allows 2 Macs per key (Gumroad's `uses` count). To free a seat, decrement
uses or disable the key in Gumroad; a disabled, refunded or charged-back key stops
working after two weekly checks.

**Sparkle update key.** Generated on jaws-mini (2026-10-03): login keychain account
`spiel`, backup `~/.spiel-secrets/sparkle_ed25519_private.txt` (0600). The public key is
`SUPublicEDKey` in `scripts/bundle.sh`. Installed copies accept only updates signed with
it. Keep a copy in 1Password; never commit it or put it on the NAS.

### Release

1. Bump `Sources/SpielCore/Version.swift` (`short` and `build`; build must grow) on main.
2. Publish a release tagged `v<version>` on that commit:

       gh release create v<version> --target main --title "Spiel <version>" --notes "…"

3. The workflow attaches `Spiel-<version>.dmg` and `appcast.xml`. Sparkle reads
   `releases/latest/download/appcast.xml`, so the newest non-prerelease release is the
   one every copy updates to (for the few minutes before the files land, the feed 404s
   and copies just check again later). It also attaches the same DMG as `Spiel.dmg`, so
   `https://github.com/morehavoc/spiel/releases/latest/download/Spiel.dmg` is always the
   newest version; the Gumroad purchase page links there instead of hosting a file.

### Locally

`scripts/release.sh` still runs the same pipeline on a Mac with a Developer ID in the
keychain and a `spiel-notary` notarytool profile (`--publish` tags and releases from
there). `scripts/release.sh --dry-run` runs everything with the self-signed "Spiel Dev
Signing" identity and skips notarization and publishing.

## Building on jaws-mini

SwiftPM's binary-artifact download hangs on this Mac (curl works). If a fresh checkout
stalls at `Downloading binary artifact`, fetch the zip with curl and serve it to a
SwiftPM mirror on localhost, or copy `.build/artifacts` from a checkout that has it.
Delete `.swiftpm/configuration/mirrors.json` afterwards.

## iPhone (Spiel Listen) → TestFlight

`.github/workflows/testflight.yml` runs on a tag `ios-v*` (e.g. `ios-v0.2.0-2`) or by hand from the
Actions tab. It archives unsigned, then Xcode's cloud signing signs for App Store distribution and
uploads. Secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY` (base64 of the .p8) — an **Admin** team key
("Spiel GitHub"), separate from the Developer-role notarization key. Build number = 100 + run number;
the marketing version is `CFBundleShortVersionString` in `native/ios/project.yml`.
