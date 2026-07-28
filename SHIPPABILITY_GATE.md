# Soundtime Shippability Gate

The shippability gate is the product bar for Soundtime. It exists to make regressions loud before they become something a human editor feels in the app.

## Required Commands

Before calling feature work done:

```sh
scripts/product-bar.sh feature
```

Equivalent direct command:

```sh
swift build && swift run Soundtime --product-bar
```

Before treating a build as a release candidate:

```sh
scripts/product-bar.sh release
```

Equivalent direct command:

```sh
swift build && swift run Soundtime --release-candidate-gate
```

## Manual Tiers

For focused local runs:

```sh
swift run Soundtime --shippability-gate --quick
swift run Soundtime --shippability-gate
swift run Soundtime --shippability-gate --full
```

The named product-bar commands are preferred for sign-off because their reports explicitly record whether the run was a feature-done bar or a release-candidate bar.

## Pass/Fail Policy

A change is not done if the product bar exits nonzero.

Hard budget failures block sign-off. They mean a user-visible contract was violated, such as delayed launch, missing cached waveform lanes, hot-path waveform fallback, selection drag latency, audio underruns, paste/delete timing, or failed import/playback behavior.

Warnings do not automatically block feature work, but they should be read. Repeated warnings or warnings in startup, audio, selection, delete, paste, import, or transcription should become follow-up work before release-candidate review.

Release-candidate runs are stricter than feature-done runs: the release-candidate bar requires zero failures, zero budget warnings, and zero regression warnings. A warning-free quick gate is the expected baseline before moving on to the next product area.

## Protected Product Loop

The gate is designed around the core editor loop:

```text
launch -> import -> see waveform -> play -> seek -> select -> delete/ripple delete -> undo/redo -> paste -> save -> reopen
```

The current gate covers this loop with deterministic fixtures, user-perceived timing budgets, visual invariant checks, hot-path contract checks, interaction replay, audio safety checks, and clear failure reports.

Export is now part of the protected product loop. The gate runs the audio export smoke so regressions in mixdown, selected range export, stems, compressed export, asset leases, long-file block rendering, and export reports fail loudly.

## Current Coverage

The quick product bar verifies:

- Golden fixture manifest and ignored generated fixture payloads.
- Startup and close lifecycle behavior.
- User-perceived timing for window visibility, waveform visibility, playback readiness, seek, selection drag, delete, paste, save, and close.
- First-frame visual invariants, including no placeholder track for multi-track projects, no blank cached waveform lanes, no duration-only waveform fallback, playhead/time alignment, transcript highlight alignment, paste flushness, delete stability, and first-frame mute/solo brightness.
- Hot-path contracts for playback, zoom, selection drag, delete, paste, diagnostics, and transcript overlay behavior.
- Deterministic interaction replay for rapid seek, fast selection drag, zoom burst, pan burst, delete/undo/delete, paste/undo/paste, loop wrap, and transcript hover/click/select.
- Import contract coverage for WAV, MP3, M4A/AAC, AIFF, FLAC, CAF, and unsupported-file handling.
- Audio safety coverage for underruns, dropped commands, output-device lifecycle, seek positioning, loop wrap consistency, edit graph swaps, and imported-format playback.
- Export coverage for full mixdowns, selected ranges, stems, compressed M4A output, mix-bus summing correctness, lease-deferred cleanup, long-file block rendering, and structured export reports.
- Transcription, diagnostics, waveform render contract, edit graph delete/paste, and API-processing smokes.

## Reports

Every run writes:

- `.build/shippability-gate/latest-report.json`
- `.build/shippability-gate/latest-report.md`
- `.build/shippability-gate/runs/<timestamp>/logs/`
- `.build/shippability-gate/runs/<timestamp>/stability-reports/`

When a run fails, it also writes a trace bundle under:

```text
.build/shippability-gate/failures/<timestamp>/
```

Attach the latest Markdown report and the failure trace bundle when reporting a regression.

## Current Product Bar

The feature-done bar runs the quick gate. It is intended to stay fast enough for frequent local use while still protecting the spine of the app: launch, waveform visibility, playback readiness, visual invariants, hot-path contracts, interaction replay, import contracts, audio safety, export smoke, transcription smoke, and API processing smoke.

The release-candidate bar runs the full gate. It adds heavier launch, dashboard lifecycle, recording, and stress coverage.

## Latest Clean Baseline

After changing the gate itself, run:

```sh
swift build
swift run Soundtime --shippability-gate-self-test
swift run Soundtime --shippability-gate --quick
```

A clean quick baseline means:

- Result is `PASSED`.
- `budgets: clean`.
- Runtime remains under the quick target.
- Interaction replay passes on both the multi-track fixture and the transcribed fixture.
- The latest report is written to `.build/shippability-gate/latest-report.json` and `.build/shippability-gate/latest-report.md`.

The self-test is required after gate implementation changes. It validates the gate's own report schema, failure bundle hints, visual-invariant budget extraction, hot-path budget extraction, and product-bar warning behavior.
