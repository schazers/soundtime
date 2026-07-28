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

The feature-done bar runs the quick gate. It is intended to stay fast enough for frequent local use while still protecting the spine of the app: launch, waveform visibility, playback readiness, visual invariants, hot-path contracts, interaction replay, import contracts, audio safety, transcription smoke, and API processing smoke.

The release-candidate bar runs the full gate. It adds heavier launch, dashboard lifecycle, recording, and stress coverage.
