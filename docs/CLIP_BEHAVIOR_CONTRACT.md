# Clip Behavior Contract

This document is the product and engineering contract for Soundtime's first-class
clip model. Changes to these rules require an explicit product decision and a
corresponding editing test.

## Identity And Time

- A clip has a stable ID independent of its name, source, position, or track.
- Timeline time and source time are distinct integer-frame ranges.
- Moving a clip changes timeline time only. Slipping changes source time only.
- Trimming changes one timeline edge and the corresponding source edge.
- Splitting preserves the original ID on the left and creates a deterministic new
  ID on the right.
- Empty timeline space is the absence of clips. It is never represented by a
  generated silent clip or a zero-gain media segment.

## Selection And Focus

- A plain click selects one clip and clears the previous clip selection.
- Command-click toggles one clip without disturbing other selected clips.
- Shift-click extends selection through canonical visual clip order, across
  tracks when necessary.
- Command-dragging empty track space adds every intersected clip to the current
  clip selection. Plain empty-space dragging remains time selection.
- Dragging empty track space creates a time selection after a three-point drag
  threshold. It does not select clips.
- Double-clicking a clip opens the track inspector and focuses that clip inside
  the track. The inspector represents the whole track.
- Main timeline and inspector have explicit transport focus. Opening the
  inspector does not silently move the project transport.
- Shift-selection is anchored at the primary clip and follows visual track and
  timeline order. Marquee selection uses clip geometry, never waveform pixels.
- "Select all following" selects clips whose starts are at or after the primary
  clip start. "Select clips in time selection" selects every intersecting clip.

## Editing

- Insert, remove, split, move, trim, slip, duplicate, rename, and property changes
  are atomic commands against one immutable clip-graph revision.
- V1 rejects clip overlap. A rejected preview and a rejected commit use the same
  collision result and identify the conflicting clips.
- Moving multiple clips preserves all relative track and timeline offsets.
- A multi-clip cross-track drag preserves relative lane offsets and rejects the
  entire placement if any destination would be invalid.
- Option-drag duplicates the frozen selection atomically. The originals remain
  visible and unchanged throughout preview and commit.
- Delete-clip removes clips and leaves implicit gaps. Ripple-delete is a distinct
  time-range command that moves later clips.
- Copy and duplicate retain source references; they do not materialize audio.
- Clip-object copy writes an internal, versioned clipboard document. Cut is copy
  followed by one atomic remove transaction. Paste preserves relative track and
  time offsets and assigns new clip IDs.
- Keyboard nudges and direct slip edits use integer timeline frames. The UI may
  expose frame, millisecond, snap-target, and grid-size increments, but a command
  never commits fractional frames.
- Locked clips reject move, trim, slip, property, remove, and range edits.
- Clip grouping is explicit metadata. Moving or deleting one grouped clip acts on
  the complete group unless the user requests an override.
- Clip repetition creates source-referencing clip instances. Consolidate and
  bounce are the only workflows in this milestone that create new media.
- A command either commits completely or leaves the graph unchanged.

## Dragging And Snapping

- Drag visuals are derived from pointer position plus a frozen command snapshot.
- The committed position must equal the final preview position.
- Auto-pan and snapping change only the proposed destination; they never mutate
  media or publish partial graph changes.
- Snapping is explicit and reports the guide that won. With snapping disabled,
  integer-frame pointer time is authoritative.
- V1 snap targets are clip edges, playhead, loop boundaries, timeline markers,
  and optional transient frames. Musical-grid targets remain dormant until the
  project has a tempo map.
- Invalid placement feedback includes the destination track and conflicting clip
  IDs. The preview and commit share the same placement validator.
- Clip crossfade edges are disabled by default. A selected clip exposes a fade
  handle only after that edge is explicitly enabled from the clip context menu.
  Disabled edges have no hidden pointer target, so normal edge dragging remains
  trim behavior. Pointer movement previews enabled fades without mutating the
  graph; mouse-up commits one typed undo transaction for the affected clip.

## Persistence, Playback, And Export

- Projects persist first-class clips and media sources. Legacy segment projects
  migrate deterministically on load.
- Playback and export are projections of the same immutable graph revision.
- One logical track may contain clips from any number of media sources.
- Waveform residency is keyed by media source, while placement and styling are
  keyed by clip and destination track. Moving a clip never changes its waveform
  identity or causes its committed waveform to disappear.
- Missing media does not change clip IDs, ranges, names, or ordering.
- Relinking replaces only a media-source path/fingerprint. Source replacement is
  a distinct operation that retains clip identity and clamps source ranges only
  after explicit confirmation.
- Undo history and active exports lease referenced media until they release it.
- Reopening a project must preserve clip IDs, ordering, ranges, properties, and
  source references exactly.

## Performance

- Pointer drag, trim, and selection frames do not rebuild the clip graph.
- Graph validation and playback projection happen at command commit boundaries,
  never once per display frame.
- Clip count, source count, and empty gaps do not imply audio materialization.

## Overlap, Fades, And Lanes

- V1 track collision policy remains reject-overlap by default. The UI explains
  the collision rather than silently overwriting audio.
- A track may opt into layered overlap only through an explicit policy. Layer
  ordering is deterministic and persisted; playback and export use that order.
- A crossfade is represented by the two participating clip fades plus linked
  crossfade metadata. Removing the overlap never leaves an invalid fade length.
- Existing persisted nonzero fades remain enabled. A zero-duration fade is the
  single persisted disabled state; no separate visibility flag may disagree
  with the audible fade.
- Take lanes and comping use stable lane IDs and source-referencing clips. A comp
  is a non-destructive selection of lane ranges, not rendered replacement media.
