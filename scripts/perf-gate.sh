#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -n "${SOUNDTIME_STABILITY_REPORT_DIR:-}" ]]; then
  mkdir -p "$SOUNDTIME_STABILITY_REPORT_DIR"
fi

mode_args=(--quick --ci)
if [[ "${1:-}" == "--full" ]]; then
  mode_args=(--ci)
fi

echo "== Soundtime audio core tests =="
swift test

echo "== Soundtime recording smoke =="
swift run Soundtime --recording-smoke

echo "== Soundtime diagnostics smoke =="
swift run Soundtime --diagnostics-smoke

echo "== Soundtime project edit round-trip smoke =="
swift run Soundtime --project-edit-roundtrip-smoke

echo "== Soundtime edit graph smoke =="
swift run Soundtime --edit-graph-smoke

echo "== Soundtime edit preview smoke =="
swift run Soundtime --edit-preview-smoke

echo "== Soundtime realtime graph publish smoke =="
swift run Soundtime --realtime-graph-publish-smoke

echo "== Soundtime timeline UX smoke =="
swift run Soundtime --timeline-ux-smoke

echo "== Soundtime timeline perf baseline =="
swift run Soundtime --timeline-perf-baseline "${mode_args[@]}"

if [[ -n "${SOUNDTIME_STABILITY_REPORT_DIR:-}" ]]; then
  expected_reports=(
    "recording-smoke.json"
    "diagnostics-smoke.json"
    "project-edit-roundtrip-smoke.json"
    "edit-graph-smoke.json"
    "edit-preview-smoke.json"
    "realtime-graph-publish-smoke.json"
    "timeline-ux-smoke.json"
    "timeline-perf-baseline.json"
  )

  for report_name in "${expected_reports[@]}"; do
    report_path="$SOUNDTIME_STABILITY_REPORT_DIR/$report_name"
    if [[ ! -s "$report_path" ]]; then
      echo "missing stability report: $report_path" >&2
      exit 1
    fi
  done
fi
