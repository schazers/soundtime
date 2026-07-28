#!/bin/zsh
set -euo pipefail

APP_PATH="${1:-dist/Soundtime.app}"
REQUIRE_UPDATES="${2:-}"
INFO_PLIST="$APP_PATH/Contents/Info.plist"

test -d "$APP_PATH"
test -f "$INFO_PLIST"
test -f "$APP_PATH/Contents/Resources/Assets.car"
test -f "$APP_PATH/Contents/Resources/Sparkle-LICENSE.txt"
test -d "$APP_PATH/Contents/Frameworks/Sparkle.framework"
plutil -lint "$INFO_PLIST"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO_PLIST" 2>/dev/null || true)"
public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST" 2>/dev/null || true)"
if [[ "$REQUIRE_UPDATES" == "--require-updates" && ( -z "$feed_url" || -z "$public_key" ) ]]; then
  print -u2 "FAIL: production bundle requires SUFeedURL and SUPublicEDKey"
  exit 1
fi
if [[ -n "$feed_url" || -n "$public_key" ]]; then
  [[ "$feed_url" == https://* ]] || {
    print -u2 "FAIL: update feed is not HTTPS"
    exit 1
  }
  [[ -n "$public_key" ]] || {
    print -u2 "FAIL: update feed exists without SUPublicEDKey"
    exit 1
  }
  [[ "$public_key" =~ '^[A-Za-z0-9+/]{43}=$' ]] || {
    print -u2 "FAIL: SUPublicEDKey is not a valid 32-byte base64 Ed25519 public key"
    exit 1
  }
fi

print "PASS: Soundtime application bundle is structurally valid."
