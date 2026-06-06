#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mode_args=(--quick --ci)
if [[ "${1:-}" == "--full" ]]; then
  mode_args=(--ci)
fi

echo "== Soundtime audio core tests =="
swift test

echo "== Soundtime recording smoke =="
swift run Soundtime --recording-smoke

echo "== Soundtime project edit round-trip smoke =="
swift run Soundtime --project-edit-roundtrip-smoke

echo "== Soundtime edit graph smoke =="
swift run Soundtime --edit-graph-smoke

echo "== Soundtime timeline perf baseline =="
swift run Soundtime --timeline-perf-baseline "${mode_args[@]}"
