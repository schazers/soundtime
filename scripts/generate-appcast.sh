#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
RELEASES_DIR="${1:-$ROOT_DIR/dist/releases}"
DOWNLOAD_URL_PREFIX="${SOUNDTIME_RELEASE_DOWNLOAD_URL_PREFIX:-}"
GENERATE_APPCAST="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

[[ -x "$GENERATE_APPCAST" ]] || swift build
[[ -d "$RELEASES_DIR" ]] || {
  print -u2 "Release directory does not exist: $RELEASES_DIR"
  exit 1
}
if [[ -n "$DOWNLOAD_URL_PREFIX" && "$DOWNLOAD_URL_PREFIX" != https://* ]]; then
  print -u2 "SOUNDTIME_RELEASE_DOWNLOAD_URL_PREFIX must use HTTPS"
  exit 1
fi

arguments=()
if [[ -n "$DOWNLOAD_URL_PREFIX" ]]; then
  arguments+=(--download-url-prefix "$DOWNLOAD_URL_PREFIX")
fi
"$GENERATE_APPCAST" "${arguments[@]}" "$RELEASES_DIR"

plutil -lint "$ROOT_DIR/Config/Info.plist" >/dev/null
print "$RELEASES_DIR/appcast.xml"
