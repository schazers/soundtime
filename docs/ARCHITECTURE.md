# Soundtime Architecture

Soundtime keeps the realtime frame and audio paths deliberately small. Domain
state may produce immutable projections for those paths, but rendering and audio
callbacks never own project mutation.

## Ownership

### Editing domain

`SoundtimeEditing` owns normalized selections, trim ranges, and the segment
arrangement algebra used by every editable audio source.

- `AudioSegmentArrangement` is the sole implementation of insert, replace,
  ripple delete, clear, gain, fade, split, heal, slip, and trim semantics.
- `AudioEditTimeline` adapts that algebra to decoded buffers.
- `AudioFileEditTimeline` adapts it to durable file-backed sources and
  persistence.
- Format-specific import code must not add format-specific edit behavior.

### Project session

`ProjectSession` is the authoritative owner of open-project track identity,
selection, edit graph, project URL, and revision counters. `WorkspaceView`
temporarily forwards legacy property names to this session while UI
orchestration is extracted.

An edit must update the session first. Playback, timeline rendering, persistence,
and launch caches receive projections of that committed state.

### Playback

`ProjectPlaybackProjection` is the only policy that selects the playable source
for a project track. It prefers a compatible editable file timeline, then an
unedited file, then decoded/timeline data.

Playback code consumes the resulting immutable `ProjectPlaybackTrack` values. It
does not decide how imports or edits should be represented.

`PlaybackEngineFactory` retains three explicit environment switches as recovery
and development controls: legacy playback, direct realtime playback, and
AudioUnit output. They select complete playback-engine implementations at
startup; they are not per-format or per-edit behavior branches.

### Import

All supported formats enter through the same `loadDroppedAudioFile` admission
point. WAV keeps its sparse, file-backed preparation optimization; other
supported formats use the proxy-first importer. Both paths must produce the same
`ProjectTrack` and `AudioFileEditTimeline` semantics before an edit can run.

### Launch waveform cache

`ProjectLaunchCacheStore` is the production read/write boundary for launch
visuals. Atomic generation bundles are authoritative. Legacy standalone
sidecars are migration-only read fallbacks and are written only if atomic bundle
publication fails.

Launch caches are derived artifacts. Failure or staleness may reduce first-paint
quality but must never change project truth or block project loading.

### Async work

Track-scoped replaceable work uses `KeyedTaskRegistry`. A replacement cancels
the previous generation, and completion is accepted only while its generation
is current.

This applies to materialization, portable paste preparation, optimistic delete
previews, waveform refinement, and launch waveform cache work. Project teardown
must cancel each registry as a unit.

## Edit Transaction Rules

1. Resolve command scope and source frames once.
2. Capture one project snapshot for undo.
3. Mutate the edit graph and track arrangements synchronously.
4. Publish visual and playback projections from that committed revision.
5. Start optional materialization, waveform refinement, autosave, and cache work
   only after the visible edit is committed.
6. Undo and redo restore project snapshots without re-running an edit command.
7. A stale async completion must never mutate a newer project revision.

## Hot-Path Rules

During playback, seek, zoom, pan, selection drag, delete, and paste:

- no CPU waveform geometry construction;
- no synchronous waveform conversion or upload;
- no project or launch-cache encoding;
- no transcript layout rebuild per frame;
- no blocking wait for background work;
- no mutation from a stale async generation.

The shippability gate and dedicated smoke harnesses enforce these contracts.

## Migration Direction

`WorkspaceView` remains the largest orchestration surface. New domain behavior
must not be added directly to it. Extract pure policy first, then inject or call
that policy from the view. UI-only layout and event routing may remain in the
view until their behavior is stable enough to move without introducing a second
state owner.

The standalone launch-cache stores also remain for on-disk migration and direct
format tests. Production code must use `ProjectLaunchCacheStore`; deleting the
legacy readers would strand projects written by older builds.
