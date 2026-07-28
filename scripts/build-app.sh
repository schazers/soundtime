#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
source "$ROOT_DIR/Config/version.env"

CONFIGURATION="${SOUNDTIME_CONFIGURATION:-release}"
OUTPUT_DIR="${SOUNDTIME_OUTPUT_DIR:-$ROOT_DIR/dist}"
APP_PATH="$OUTPUT_DIR/Soundtime.app"
CONTENTS="$APP_PATH/Contents"
INFO_PLIST="$CONTENTS/Info.plist"
ASSET_OUTPUT="$CONTENTS/Resources"

cd "$ROOT_DIR"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/private/tmp/soundtime-swiftpm-module-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/private/tmp/soundtime-swift-module-cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/soundtime-clang-module-cache}"
swift build -c "$CONFIGURATION"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
SPARKLE_FRAMEWORK="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

test -x "$BIN_DIR/Soundtime"
test -d "$SPARKLE_FRAMEWORK"

rm -rf "$APP_PATH"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Frameworks" "$ASSET_OUTPUT"
cp "$BIN_DIR/Soundtime" "$CONTENTS/MacOS/Soundtime"
ditto "$SPARKLE_FRAMEWORK" "$CONTENTS/Frameworks/Sparkle.framework"
cp "$ROOT_DIR/Config/Info.plist" "$INFO_PLIST"

for substitution in \
  "SOUNDTIME_BUNDLE_IDENTIFIER:$SOUNDTIME_BUNDLE_IDENTIFIER" \
  "SOUNDTIME_MARKETING_VERSION:$SOUNDTIME_MARKETING_VERSION" \
  "SOUNDTIME_BUILD_VERSION:$SOUNDTIME_BUILD_VERSION" \
  "SOUNDTIME_MINIMUM_MACOS_VERSION:$SOUNDTIME_MINIMUM_MACOS_VERSION"
do
  key="${substitution%%:*}"
  value="${substitution#*:}"
  sed -i '' "s|\$($key)|$value|g" "$INFO_PLIST"
done

if [[ -n "${SOUNDTIME_UPDATE_FEED_URL:-}" ]]; then
  [[ "$SOUNDTIME_UPDATE_FEED_URL" == https://* ]] || {
    print -u2 "SOUNDTIME_UPDATE_FEED_URL must use HTTPS"
    exit 1
  }
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SOUNDTIME_UPDATE_FEED_URL" "$INFO_PLIST"
fi
if [[ -n "${SOUNDTIME_SPARKLE_PUBLIC_KEY:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SOUNDTIME_SPARKLE_PUBLIC_KEY" "$INFO_PLIST"
fi

xcrun actool \
  --compile "$ASSET_OUTPUT" \
  --platform macosx \
  --minimum-deployment-target "$SOUNDTIME_MINIMUM_MACOS_VERSION" \
  --app-icon AppIcon \
  --output-partial-info-plist "$OUTPUT_DIR/asset-info.plist" \
  "$ROOT_DIR/Resources/Assets.xcassets" >/dev/null

cp "$ROOT_DIR/.build/artifacts/sparkle/Sparkle/LICENSE" \
  "$ASSET_OUTPUT/Sparkle-LICENSE.txt"

plutil -lint "$INFO_PLIST" >/dev/null
SIGNING_IDENTITY="${SOUNDTIME_CODESIGN_IDENTITY:--}"
TIMESTAMP_ARGUMENT=(--timestamp)
APP_ENTITLEMENTS="$ROOT_DIR/Config/Soundtime.entitlements"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  TIMESTAMP_ARGUMENT=(--timestamp=none)
  APP_ENTITLEMENTS="$OUTPUT_DIR/Soundtime.local.entitlements"
  cp "$ROOT_DIR/Config/Soundtime.entitlements" "$APP_ENTITLEMENTS"
  /usr/libexec/PlistBuddy \
    -c "Add :com.apple.security.cs.disable-library-validation bool true" \
    "$APP_ENTITLEMENTS"
fi

while IFS= read -r nested_bundle; do
  codesign --force --sign "$SIGNING_IDENTITY" \
    --preserve-metadata=identifier,entitlements,requirements,flags,runtime \
    "${TIMESTAMP_ARGUMENT[@]}" \
    "$nested_bundle"
done < <(find "$CONTENTS/Frameworks/Sparkle.framework" -depth \
  \( -name "*.xpc" -o -name "*.app" \) -type d)

codesign --force --sign "$SIGNING_IDENTITY" \
  --preserve-metadata=identifier,entitlements,requirements,flags,runtime \
  "${TIMESTAMP_ARGUMENT[@]}" \
  "$CONTENTS/Frameworks/Sparkle.framework"

codesign --force --sign "$SIGNING_IDENTITY" \
  --options runtime \
  "${TIMESTAMP_ARGUMENT[@]}" \
  --entitlements "$APP_ENTITLEMENTS" \
  "$APP_PATH"

print "$APP_PATH"
