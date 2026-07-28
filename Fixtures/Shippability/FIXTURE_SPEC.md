# Soundtime Shippability Fixture Spec

This directory contains the committed contract for Soundtime's golden shippability fixtures.
The generated media and project payloads live under versioned directories such as `v1/` and are intentionally ignored by Git.

## Commands

Build the canonical fixture set in the default local workspace path:

```sh
swift run Soundtime --build-shippability-fixtures
```

Verify an existing generated fixture set:

```sh
swift run Soundtime --verify-shippability-fixtures
```

For a future shippability gate or CI run, prefer a disposable cache/temp output instead of the workspace path:

```sh
swift run Soundtime --build-shippability-fixtures --fixtures-output /tmp/soundtime-shippability-fixtures/v1
swift run Soundtime --verify-shippability-fixtures --fixtures-output /tmp/soundtime-shippability-fixtures/v1
```

Run the master shippability gate with the default cached fixture bundle:

```sh
swift run Soundtime --shippability-gate
swift run Soundtime --shippability-gate --quick
```

The gate verifies `.build/shippability-fixtures/v1` before using it. If the cache is missing or invalid, it rebuilds it once; later runs reuse it. To force a clean fixture rebuild:

```sh
swift run Soundtime --shippability-gate --rebuild-fixtures
```

To preserve the previous run-local fixture behavior for a one-off clean run:

```sh
swift run Soundtime --shippability-gate --disposable-fixtures
```

## Naming Scheme

Audio fixtures use:

```text
st-ship-audio-NNN-role-duration.ext
```

Project fixtures use:

```text
st-ship-project-NNN-scenario.soundtime
```

Fixture IDs and file names are stable. If the fixture list changes, update both this spec and the manifest stability checks in `ShippabilityFixtureBuilder`.

## Audio Fixtures

| ID | File | Format | Duration | Purpose |
| --- | --- | --- | --- | --- |
| `st-ship-audio-001` | `audio/st-ship-audio-001-short-voice-12s.wav` | WAV | 12s | Tiny spoken fixture for launch/edit smoke tests. |
| `st-ship-audio-002` | `audio/st-ship-audio-002-long-podcast-180s.wav` | WAV | 180s | Longer voice-like fixture for startup and playback timing. |
| `st-ship-audio-003` | `audio/st-ship-audio-003-music-bed-90s.wav` | WAV stereo | 90s | Music-bed fixture for zoom/render stress. |
| `st-ship-audio-004` | `audio/st-ship-audio-004-transient-clicks-60s.wav` | WAV | 60s | Transient-heavy fixture for playhead glow and marker alignment. |
| `st-ship-audio-005` | `audio/st-ship-audio-005-import-podcast-editable-proxy-45s.wav` | WAV stereo | 45s | Editable proxy paired with compressed import fixtures. |
| `st-ship-audio-006` | `audio/st-ship-audio-006-import-podcast-45s.mp3` | MP3 | 45s | Compressed import success fixture. |
| `st-ship-audio-007` | `audio/st-ship-audio-007-import-voice-30s.aiff` | AIFF | 30s | AIFF import success fixture. |
| `st-ship-audio-008` | `audio/st-ship-audio-008-import-music-30s.m4a` | M4A/AAC | 30s | MPEG-4 audio import success fixture. |
| `st-ship-audio-009` | `audio/st-ship-audio-009-import-voice-30s.aac` | AAC | 30s | Standalone AAC import success fixture. |
| `st-ship-audio-010` | `audio/st-ship-audio-010-import-music-30s.flac` | FLAC | 30s | FLAC import success fixture. |
| `st-ship-audio-011` | `audio/st-ship-audio-011-import-clicks-20s.caf` | CAF | 20s | Core Audio Format import success fixture. |
| `st-ship-audio-012` | `audio/st-ship-audio-012-unsupported-ogg-placeholder.ogg` | Ogg | 0s | Recognized unsupported-file fixture for the unsupported import modal path. |
| `st-ship-audio-013` | `audio/st-ship-audio-013-true-long-podcast-30m.wav` | WAV | 1800s | True podcast-scale WAV fixture for full release startup and playback confidence. |

Supported import formats covered by v1: WAV, AIFF, MP3, M4A, AAC, FLAC, and CAF.
Recognized unsupported formats covered by v1: Ogg.

## Project Fixtures

| ID | File | Tracks | Duration | Purpose |
| --- | --- | ---: | --- | --- |
| `st-ship-project-001` | `projects/st-ship-project-001-short-wav-launch.soundtime` | 1 | 12s | Minimal short WAV launch project. |
| `st-ship-project-002` | `projects/st-ship-project-002-long-wav-startup.soundtime` | 1 | 180s | Long WAV startup and first-playback project. |
| `st-ship-project-003` | `projects/st-ship-project-003-mp3-import-proxy.soundtime` | 1 | 45s | MP3-origin project represented by an editable WAV proxy. |
| `st-ship-project-004` | `projects/st-ship-project-004-three-track-session.soundtime` | 3 | 180s | Mixed session with mute/solo state and shared edit group. |
| `st-ship-project-005` | `projects/st-ship-project-005-edited-delete-paste.soundtime` | 1 | 85.35s | Edited timeline with delete, insert-silence, and fade state. |
| `st-ship-project-006` | `projects/st-ship-project-006-transcribed-podcast.soundtime` | 1 | 180s | Podcast track with deterministic transcript data. |
| `st-ship-project-007` | `projects/st-ship-project-007-stress-100-tracks.soundtime` | 100 | 12s | Layout/render stress project with compact previews. |
| `st-ship-project-008` | `projects/st-ship-project-008-true-long-wav-release.soundtime` | 1 | 1800s | True 30-minute WAV project used by full release-gate coverage. |

Every project fixture must include launch waveform previews on every track.

## Disposal Rule

Generated projects contain absolute local file paths, so they are disposable build artifacts.
Regenerate them after moving the workspace, changing machines, or changing the fixture catalog.
Do not commit `Fixtures/Shippability/v*/`.

## Step 2 Gate Direction

The master shippability gate should verify and reuse a local cache by default, regenerate it when the cache is missing or stale, and only use disposable run-local fixtures when explicitly requested. The gate must still verify the manifest contract before running launch, import, edit, render, diagnostics, transcription, and export checks.
