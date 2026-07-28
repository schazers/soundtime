#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
  cat <<'USAGE'
Soundtime product bar

Usage:
  scripts/product-bar.sh feature
  scripts/product-bar.sh release

Aliases:
  feature: quick, done
  release: rc, full

The feature bar is required before calling feature work done.
The release bar is required before treating a build as a release candidate.
USAGE
}

mode="${1:-feature}"

case "$mode" in
  feature|quick|done)
    swift build
    swift run Soundtime --product-bar
    ;;
  release|rc|full)
    swift build
    swift run Soundtime --release-candidate-gate
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac
