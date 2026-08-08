# Extreme Timeline Performance

Soundtime's extreme timeline gate protects the interaction contract for very
large editing sessions. It combines the expensive timeline features in one
deterministic workload rather than benchmarking isolated subsystems.

## Extreme Golden Project

The full fixture profile generates:

`st-ship-project-009-extreme-timeline.soundtime`

The project contains:

- 1,000 tracks
- 128 clips per track, or 128,000 first-class clips
- 256 automation points per track, or 256,000 automation points
- transcript data on every eighth track
- four shared source-resident waveform assets
- 7,200 seconds of project time
- stable clip, source, transcript, and automation identities

The generated media is intentionally compact. The fixture stresses project
topology, rendering, layout, persistence, and interaction without requiring a
huge binary fixture in Git. Generated fixtures are ignored and can always be
recreated deterministically.

Build and verify the full fixture set with:

```sh
swift run Soundtime --build-shippability-fixtures --fixture-profile full
swift run Soundtime --verify-shippability-fixtures --fixture-profile full
```

## Interactive Performance Workload

The dedicated Metal benchmark keeps the same hostile scale in memory while it
simultaneously performs:

- horizontal pan
- continuously changing horizontal zoom
- vertical track scrolling
- active playback and playhead movement
- a selected region on a currently visible lane
- waveform mip selection and source-to-clip mapping
- clip chrome for a 128,000-clip graph
- volume automation curves backed by 256,000 points
- transcript virtualization and layout

It renders a 1,920 x 1,080 point viewport at 2x backing scale. The measured
window is 360 frames after at least 120 warmup frames and confirmed waveform
residency. The navigation cycle continues during measurement; warmup cannot
consume the pan or zoom workload.

Run it with:

```sh
swift run -c release Soundtime --extreme-timeline-performance --ci
```

The strict timing contract is a release-build contract. Debug builds remain
useful for correctness and diagnostics, but unoptimized Swift and assertions
do not represent the binary shipped to users.

## Contract

On the reference development machine, strict mode requires:

- zero CPU submission frames over the 144 Hz frame interval (6.944 ms)
- zero dropped 144 Hz frames
- CPU p95 no greater than 90% of the 144 Hz interval (6.25 ms)
- GPU p95 no greater than 90% of the 144 Hz interval
- GPU maximum no greater than one 144 Hz interval
- no CPU waveform vertices
- no synchronous waveform uploads during the measured interaction
- resident waveform mip cache bounded by source count, not clip or track count
- visible lane work bounded to the viewport plus overscan

The JSON result reports overall CPU and GPU percentiles plus separate state
update, transcript layout, and Metal submission timings. This makes a failure
actionable instead of merely saying that the timeline was slow.

The command may take up to three steady-state samples when a sample fails only
because of an isolated wall-clock timing outlier. It reports the accepted
attempt count. This filters unrelated macOS scheduling preemption while keeping
the contract strict: every accepted sample still has zero frames over budget,
and a sustained CPU or GPU regression fails every attempt.

## Release Gate

The extreme benchmark runs in the full shippability gate:

```sh
swift run -c release Soundtime --shippability-gate --full
```

Quick and standard modes omit the extreme project so ordinary local iteration
stays fast. Full mode is the release bar.

## Interpreting "Perfect Smoothness"

No desktop application can promise a fixed frame rate for literally unbounded
data on every machine. Soundtime therefore defines a concrete, repeatable
contract: the extreme fixture above must produce zero missed 144 Hz submission
frames with CPU and GPU headroom on the reference hardware. The generated
project and machine-readable report make future regressions loud and let the
fixture scale increase deliberately as the product grows.
