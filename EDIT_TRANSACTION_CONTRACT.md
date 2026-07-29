# Soundtime Edit Transaction Contract

Delete, Clear Gap, Cut, Paste, Undo, and Redo are project transactions. They
must never derive their target from mutable UI state after command dispatch.

## Canonical Time

- Command ranges use a half-open project-time interval `[startTick, endTick)`.
- Project ticks are integer nanoseconds. Floating-point progress is a view-only
  projection and is never stored in a command or undo record.
- A range selection always carries its anchor track UUID.
- A non-empty range selection takes precedence over whole-track selection.
- A command without an explicit, live anchor track UUID is rejected.

## Scope

- `Track` targets only the anchor track.
- `Selected` targets the captured set of selected track UUIDs.
- `Group` targets the captured members of the anchor track's edit group.
- `All` targets the captured set of all project track UUIDs.
- Scope membership is captured when the command is created. Array indexes are
  not command identity.
- Every target is validated before the transaction commits. Unsupported or
  missing targets reject the complete transaction; partial edits are forbidden.

## Delete And Clear Gap

- Ripple Delete removes the intersection of the project range with each target
  track and shifts later audio left by the project-range duration.
- Tracks with no overlap remain unchanged.
- Clear Gap removes audio inside the range without shifting later audio.
- The playhead moves to the command range's start at command dispatch and
  remains there after commit, undo, and redo according to the recorded outcome.
- Delete and Clear Gap share one planner and one commit path.

## Cut

- Standard Cut is track-scoped in version 1.
- Cut captures an immutable clipboard source-span description before mutation.
- Clipboard identity and content are committed with the edit transaction.
- Background sample decoding may enrich that clipboard entry, but an older task
  may never overwrite a newer clipboard entry.
- Multi-track Ripple Cut requires a separate, explicit command in a later
  release.

## Paste

- Paste targets the active track at the captured playhead project tick.
- The pasted interval begins exactly at that tick and contains no visual or
  model-space gap.
- Later audio on the destination track shifts right by the inserted duration.
- The playhead remains at the insertion tick.
- The inserted interval becomes the selected range.
- Same-source media is inserted by immutable source-span reference.
- The version 1 track arrangement references one audio source, so a same-source
  paste commits immediately as a metadata splice.
- A cross-source paste captures an immutable command, clipboard asset lease,
  destination revision, and destination edit state before starting its visual.
  It then streams the prepared result on the dedicated paste worker and commits
  that result atomically only while the captured revision is still current.
- Cross-source preparation never blocks the main thread, never allocates a
  destination-sized sample buffer, is cancelable, and removes stale output.
- A future multi-source clip graph can make cross-source paste an immediate
  metadata splice too. Until that migration, the visual begins immediately but
  the cross-source model commit is authorized only by successful preparation.

## Atomic Commit

- Planning is pure and does not mutate UI, playback, renderer, or persistence.
- Validation completes before animation or commit.
- One commit advances the project edit revision exactly once.
- Render and playback publications identify the same committed revision.
- An animation is a presentation of the old and new immutable states. It does
  not delay or authorize a same-source model commit. Cross-source paste is the
  explicit version 1 exception described above because the destination model
  cannot yet retain references to multiple audio sources.

## Undo And Redo

- Every committed transaction creates one undo record containing the immutable
  before and after edit states plus deterministic UI outcomes.
- Undo and redo are revision swaps, not reconstructions from renderer or audio
  snapshots.
- A new edit after Undo clears the redo stack.
- Undo and redo preserve viewport and loop state unless the transaction itself
  changed them.
- Selection and playhead restoration are explicitly recorded per transaction.

## Background Work

- Waveform building, waveform refinement, decoding, materialization, autosave,
  diagnostics formatting, and cleanup are optional consequences of a commit.
- None may run synchronously in the edit critical path.
- Background results are revision-keyed and discarded when stale.
- Cache failure may reduce refinement quality but may not change audible or
  visual edit placement.

## Performance Budgets

- Command dispatch to first submitted visual frame: at most one 144 Hz frame
  (`6.94 ms`) at p99.
- Main-thread planning and preparation before the visual response: `2 ms`
  target, `4 ms` hard stress-project limit.
- The complete synchronous edit action, including immutable render/playback
  publication, must remain below `16 ms` in the debug 100-track replay. Release
  builds target one 144 Hz frame.
- Undo and redo publication: at most one 144 Hz frame at p99.
- No edit may trigger CPU waveform fallback, synchronous waveform upload,
  source decoding, source materialization, or main-thread persistence.
- Cross-source media preparation is not part of the main-thread edit path; it
  runs on its cancelable worker after the immediate visual response.

## Acceptance Matrix

The automated gate covers:

- WAV, MP3 proxy, M4A/AAC proxy, AIFF, FLAC, API output, and recording sources.
- 44.1 kHz, 48 kHz, and 96 kHz sources.
- One, three, and one hundred tracks with unequal durations.
- Track, Selected, Group, and All scopes.
- Paused and active playback.
- Ranges at project start, middle, end, beyond shorter tracks, and across clip
  boundaries.
- At least 1,000 Delete/Undo/Redo, Cut/Undo/Redo, and Paste/Undo/Redo cycles.
- Commands interrupted at every former delayed-handoff boundary.
