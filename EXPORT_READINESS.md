# Soundtime Export Readiness

This document is the release contract for v1 export. Export is done only when the automated smoke and the manual acceptance matrix both pass.

## V1 Contract

- Export runs from an immutable snapshot of the edit graph.
- The user can keep editing while a background export continues rendering the original snapshot.
- Export never blocks the realtime audio callback.
- Export never requires waveform cache rebuilds.
- Source assets referenced by an export snapshot stay alive until the export completes or is canceled.
- Mixdown sums tracks on an unclipped internal bus and clips only at the final file boundary.
- WAV, selected-range WAV, stems, and compressed M4A are covered by the automated export smoke.
- Export progress reflects the current stage: preparing, rendering, encoding, finishing, completed, canceled, or failed.
- Closing the export window does not cancel the export.
- The top-bar export chip reopens the export window while a job is active.
- Export completion writes a structured `.soundtime-export.json` report next to the output.

## Automated Coverage

Run:

```sh
swift run Soundtime --audio-export-smoke
swift run Soundtime --shippability-gate --quick
```

The export smoke covers:

- Full WAV mixdown.
- Selected-range WAV export.
- WAV stems with sanitized filenames.
- Mix-bus summing correctness without per-track clamp distortion.
- Streaming compressed M4A export.
- Long-file block rendering shape.
- Export report creation and contents.
- Export source asset lease acquire/release.
- Deferred source deletion while an export lease is active.

## Manual Acceptance Matrix

Run these against the golden fixture projects before release candidate sign-off:

- Export full mixdown from `short_wav.soundtime`; output duration and audible content match the timeline.
- Export selected range from the timeline context menu; output starts exactly at the selected region and contains no leading gap.
- Export selected range from the File menu; output matches the context-menu export.
- Export stems from `three_track_edit.soundtime`; every track produces one WAV with a readable sanitized filename.
- Export mixdown plus stems; folder contains the mixdown and each track stem.
- Export M4A full mixdown; output is playable in Finder/QuickTime.
- Start a long export, close the export window, then reopen it from the top-bar chip; progress continues.
- Cancel a long export; partial output is removed or unusable partial files are not surfaced as successful outputs.
- Export while editing the project; the output matches the snapshot from export start, not later edits.
- Delete clips while an export is running; the export completes without missing-source errors.
- Export a project with muted tracks; muted tracks do not appear in the mixdown.
- Export after undo/redo cycles; output matches the current audible timeline.
- Export after importing MP3/M4A/AIFF/FLAC; output plays and matches the imported audio.
- Export with no audio selected via selected-region command; command is disabled or shows a clear error.
- Export to a read-only or invalid location; UI shows a clear failure and the Development Console records the provider error.

## Blockers

Do not call export production-ready if any of these are true:

- Export blocks pointer interactions or playback.
- Export mutates the live timeline while rendering.
- Export can lose source files after a user edit.
- Progress freezes without a visible stage change.
- Selected-region export has leading/trailing timing drift.
- Mixdowns audibly differ from playback semantics.
- Compressed export requires full rendered audio in memory.
- Reports are missing for successful exports.
