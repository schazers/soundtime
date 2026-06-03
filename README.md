# Soundtime

Soundtime is a native macOS audio editor for fast, precise waveform work.

The v1 product promise is simple:

> Drop in audio. Make precise edits immediately. Export. No waiting.

## First Milestone

This repository currently contains the native app shell:

- Swift Package-based macOS executable
- AppKit window titled `Soundtime`
- Metal-backed timeline workspace with a static grid and playhead

## Run

```sh
swift run Soundtime
```

## Build

```sh
swift build
```
