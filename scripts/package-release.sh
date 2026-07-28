#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
source "$ROOT_DIR/Config/version.env"

: "${SOUNDTIME_DEVELOPER_ID_APPLICATION:?Set SOUNDTIME_DEVELOPER_ID_APPLICATION}"
: "${SOUNDTIME_NOTARY_PROFILE:?Set SOUNDTIME_NOTARY_PROFILE}"
: "${SOUNDTIME_SPARKLE_PUBLIC_KEY:?Set SOUNDTIME_SPARKLE_PUBLIC_KEY}"
: "${SOUNDTIME_UPDATE_FEED_URL:?Set SOUNDTIME_UPDATE_FEED_URL}"

[[ "$SOUNDTIME_UPDATE_FEED_URL" == https://* ]] || {
  print -u2 "SOUNDTIME_UPDATE_FEED_URL must use HTTPS"
  exit 1
}

export SOUNDTIME_CODESIGN_IDENTITY="$SOUNDTIME_DEVELOPER_ID_APPLICATION"
"$ROOT_DIR/scripts/build-app.sh"

APP_PATH="$ROOT_DIR/dist/Soundtime.app"
ARCHIVE_PATH="$ROOT_DIR/dist/Soundtime-$SOUNDTIME_MARKETING_VERSION.zip"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
"$ROOT_DIR/scripts/verify-release.sh" "$APP_PATH" --require-updates
rm -f "$ARCHIVE_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"

xcrun notarytool submit "$ARCHIVE_PATH" \
  --keychain-profile "$SOUNDTIME_NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
rm -f "$ARCHIVE_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"

print "$ARCHIVE_PATH"
