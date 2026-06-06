# Soundtime

Soundtime is a native macOS audio editor for fast, precise waveform work.

The v1 product promise is simple:

> Drop in audio. Make precise edits immediately. Export. No waiting.

## First Milestone

This repository currently contains the native app shell:

- Swift Package-based macOS executable
- AppKit window titled `Soundtime`
- Metal-backed timeline workspace with a static grid and playhead
- Single-file audio drag and drop with lightweight filename, duration, and size metadata
- Progressive sparse WAV previews so dropped files become visible, playable, and visually refine before full decode completes
- WAV PCM decode into an in-memory floating-point buffer
- High-resolution full-file waveform overview rendered through Metal
- Spacebar playback for decoded WAV files with a moving playhead
- Header time readout for playhead position, timeline duration, and selection bounds
- Draggable start/end trim handles for fast boundary trims
- Click-drag timeline selection with selected duration in the header
- Pinch or Option-scroll to zoom the waveform, and scroll to pan the visible timeline
- Zoomed playback pages the visible timeline forward as the playhead reaches the right edge
- Delete/Backspace removes the selected range non-destructively
- Command-Z restores the previous edit timeline
- Click the waveform to seek the playhead
- Command-E exports the current edited timeline as WAV

## Run

```sh
swift run Soundtime
```

## Build

```sh
swift build
```

## Regression Gates

Run the fast local gate before renderer or audio-engine changes:

```sh
scripts/perf-gate.sh
```

That runs the audio-core tests, the recording smoke harness, and the quick 10/50/100-track Metal timeline perf budget. Use `scripts/perf-gate.sh --full` for the longer 10/50/100/250-track baseline.
