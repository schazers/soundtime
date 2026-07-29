# Soundtime V1 Export Release Contract

Export is release-ready only when the automated commands and the manual audio
acceptance matrix in this document pass on the release build.

## Product Semantics

- Export captures an immutable edit-graph snapshot and renders that snapshot in
  the background.
- Editing and playback may continue while export runs. Later edits never change
  an in-flight export.
- Only one export job may run per project window. Starting another job presents
  an explicit keep-or-cancel choice.
- Closing the export progress window does not cancel the job. The top-bar export
  chip reopens it.
- Cancel removes staged output and never replaces a previously successful file.
- Source files referenced by the snapshot are leased until completion or
  cancellation. Project cleanup defers deleting leased files.
- An interrupted process may leave hidden staging artifacts. Artifacts older
  than 24 hours are removed during the next export preflight.

## Audio Contract

- Offline export uses the same C++ segment/mix renderer as realtime playback.
- The internal mix bus is floating point and is not clipped per track.
- Integer WAV and compressed formats clamp only at the final encoding boundary.
- 32-bit float WAV preserves headroom above 0 dBFS.
- Full and selected-range mixdowns honor mute, solo, track gain, timeline edits,
  segment fades, project time, and source sample-rate conversion.
- Explicit single-track range export renders the selected track even when that
  track is muted.
- An all-muted mixdown is a valid silent file.
- Stem defaults are all tracks and post-fader gain. The UI also exposes audible
  tracks and pre-fader gain.

## Formats

- WAV: 16-bit PCM, 24-bit PCM (default), and 32-bit float.
- M4A/AAC: 128, 192 (default), or 256 kbps.
- MP3: exposed only when the current macOS installation reports an MP3 encoder.
- Standard RIFF WAV is limited to 4 GB. V1 rejects larger WAV jobs with an
  actionable message instead of writing a corrupt file.
- Compressed output is streamed through the system encoder; Soundtime does not
  hold a full rendered file in memory.

## Output Safety

Before rendering, Soundtime checks:

- destination/source collisions;
- source identity and modification metadata;
- destination writability;
- conservative free-space capacity;
- WAV RIFF capacity;
- system encoder availability and writer creation.

Audio is written to a sibling hidden staging file. Soundtime validates that file
for decodability, frame count, sample rate, channel count, and finite first/last
samples. The source identity is checked again immediately before an atomic
rename publishes the final file.

Stem files are built in a hidden staging directory. A commit failure rolls back
newly published files. Stem names are sanitized, length bounded, and unique
under case- and diacritic-insensitive comparison.

## Progress, Errors, And Reports

Progress stages are preparing, rendering/encoding, validating, committing,
completed, canceled, and failed. Cancellation visibly enters a non-interactive
`Canceling...` state while partial output is removed.

Stage transitions and failures are recorded in the Development Console. A
successful export attempts to write a structured `.soundtime-export.json`
diagnostic report containing:

- Soundtime version/build;
- job, scope, format, WAV encoding, compressed bitrate, and stem policy;
- sample rate, channels, frame range, and rendered frame count;
- source fingerprints;
- output validation results;
- peak and over-range sample statistics;
- output paths and elapsed time.

The report is diagnostic metadata, not the user's audio deliverable. A report
write failure is logged but does not discard already validated audio.

## Automated Gate

Run:

```sh
swift build
swift test
swift run Soundtime --audio-export-ui-smoke
swift run Soundtime --audio-export-smoke
swift run Soundtime --shippability-gate --quick
```

Before a release candidate, also run:

```sh
swift run Soundtime --product-bar
swift run Soundtime --shippability-gate --full
```

The dedicated export suites cover:

- all WAV encodings;
- every compressed encoder reported available on the test Mac;
- every advertised compressed quality;
- full mix, selected range, edited timelines, stems, and mixdown plus stems;
- mute, solo, gain, all-muted, explicit-track, and resampling semantics;
- realtime/offline renderer differential behavior;
- floating-point mix-bus headroom;
- long block-based rendering;
- transactional replacement and rollback;
- cancellation preserving an existing output and removing partial output;
- source mutation and source/destination collision rejection;
- output validation and diagnostic reports;
- source leases, symlink aliases, deferred deletion, and lease release;
- stale partial recovery;
- case-insensitive stem naming;
- export option defaults and progress-window terminal/canceling states.

## Manual Release Acceptance

Run these on a signed release build using the golden fixture projects:

1. Export full WAV and compressed mixdowns from short and long projects. Listen
   to the beginning, an edit boundary, and the end.
2. Export a selected region from the File menu and the timeline context menu.
   Confirm sample-aligned duration and no leading gap.
3. Export stems and mixdown-plus-stems from the three-track project. Confirm
   naming, all/audible policy, and pre/post-fader behavior.
4. Export after delete, paste, split, undo, and redo. Compare the output to
   realtime playback at the same positions.
5. Export projects imported from WAV, MP3, M4A/AAC, AIFF, and FLAC.
6. Start a long export, continue seeking/editing/playing, close the progress
   window, and reopen it from the top bar. Confirm UI and audio remain smooth.
7. Cancel a long export over an existing destination. Confirm the previous file
   remains unchanged and no visible partial file remains.
8. Delete an app-owned clip source while its snapshot export is running. Confirm
   the export finishes and cleanup occurs after the lease releases.
9. Try an invalid/read-only destination, insufficient-space volume, changed
   source, and oversized WAV plan. Confirm actionable errors and no published
   partial output.
10. Verify exported files in Finder/QuickTime and at least one independent audio
    application. Confirm duration, channels, sample rate, and audible content.

## Deliberate V1 Limits

- No RF64/W64 output above 4 GB.
- No plug-in/effect-state checkpointing yet; the snapshot currently covers the
  edit graph and audio behavior implemented by Soundtime's canonical renderer.
- Codec availability is determined by macOS. MP3 may be unavailable and is then
  hidden rather than emulated by an unshipped third-party encoder.
- Loudness normalization, metadata/tag editing, dithering controls beyond the
  deterministic integer-WAV path, and batch export presets are future product
  features, not hidden V1 behavior.

Any automated gate failure is a release blocker. Any audible mismatch,
realtime interruption, published corrupt file, or snapshot/source lifetime
failure in the manual matrix is also a release blocker.
