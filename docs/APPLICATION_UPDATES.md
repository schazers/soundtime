# Soundtime Application Updates

Soundtime uses Sparkle 2 for direct-distribution updates. Sparkle owns update
signature verification, download staging, standard update dialogs, installation,
relaunch, and install-on-quit. Soundtime owns policy: delayed startup, channels,
restart blockers, preferences, and diagnostics.

## Versioning

Update `Config/version.env` for every release:

- `SOUNDTIME_MARKETING_VERSION` is the user-facing semantic version.
- `SOUNDTIME_BUILD_VERSION` is a monotonically increasing integer used by Sparkle.
- Stable releases use the default appcast channel.
- Prereleases use the `beta` channel and a prerelease marketing version.

Never reuse or decrease a build version.

## Keys And Secrets

Generate the Sparkle Ed25519 key once using Sparkle's `generate_keys` tool.
Sparkle stores the private key in the macOS Keychain. Store the public key in
release automation as `SOUNDTIME_SPARKLE_PUBLIC_KEY`. Never commit or export the
private key into this repository.

Developer ID and notarization credentials also stay outside the repository:

- `SOUNDTIME_DEVELOPER_ID_APPLICATION`
- `SOUNDTIME_NOTARY_PROFILE`
- `SOUNDTIME_SPARKLE_PUBLIC_KEY`
- `SOUNDTIME_UPDATE_FEED_URL`

## Build And Release

For a local ad-hoc signed bundle:

```sh
scripts/build-app.sh
scripts/verify-release.sh
```

For a production archive:

```sh
SOUNDTIME_DEVELOPER_ID_APPLICATION="Developer ID Application: ..." \
SOUNDTIME_NOTARY_PROFILE="soundtime-notary" \
SOUNDTIME_SPARKLE_PUBLIC_KEY="..." \
SOUNDTIME_UPDATE_FEED_URL="https://updates.soundtime.app/appcast.xml" \
scripts/package-release.sh
```

Place notarized archives in the releases directory, then run:

```sh
SOUNDTIME_RELEASE_DOWNLOAD_URL_PREFIX="https://updates.soundtime.app/releases/" \
scripts/generate-appcast.sh dist/releases
```

Upload archives first. Upload `appcast.xml` last and atomically. This prevents
clients from seeing an update whose archive is not yet available.

## Rollout Policy

Use `sparkle:phasedRolloutInterval` for normal stable releases. Critical updates
may use `sparkle:criticalUpdate` and should not be phased when the fix is urgent.
Beta items use `<sparkle:channel>beta</sparkle:channel>`.

Before publishing:

1. Run `swift test`.
2. Run the full Soundtime shippability gate.
3. Build and verify the production bundle.
4. Install the notarized bundle on a clean macOS account.
5. Test manual update, automatic update, Later/install-on-quit, and restart with
   recording/export blockers.
6. Upload the archive.
7. Publish the appcast last.

Rollback by publishing a newer build containing the prior good code. Sparkle
prevents downgrades; never rewrite an already published archive in place.
