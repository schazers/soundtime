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
- WAV PCM decode into an in-memory floating-point buffer
- Full-file waveform overview rendered through Metal
- Spacebar playback for decoded WAV files with a moving playhead
- Click-drag timeline selection with selected duration in the header
- Delete/Backspace removes the selected range non-destructively
- Command-Z restores the previous edit timeline
- Click the waveform to seek the playhead

## Run

```sh
swift run Soundtime
```

## Build

```sh
swift build
```
