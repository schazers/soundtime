# Clip Workflow Architecture

## Product Contract

`ProjectSession.clipGraph` is the only source of truth for clip identity, placement,
source mapping, gain, fades, mute, lock, color, and metadata. Timeline rendering,
realtime playback, export, clipboard operations, and undo all project from the same
graph revision.

The main timeline uses this interaction grammar:

- Click selects one clip. Clicking a grouped clip selects its group.
- Command-click toggles membership in the current clip selection.
- Shift-click selects the ordered range from the primary clip.
- Command-drag through empty timeline space adds clips intersecting the marquee.
- Dragging a selected clip moves the complete selection, including between tracks.
- Option-drag duplicates the complete selection at the previewed destination.
- Dragging a clip edge trims it. Selected clips expose fade and gain controls.
- Invalid placements remain previews, render in the invalid style, and cannot commit.
- Clip overlap is rejected in version 1. Adjacent clips may touch exactly.

## Ownership

- `TimelineView` owns pointer hit testing and transient drag presentation.
- `TimelineClipPlacementValidator` owns collision truth for preview and commit.
- `TimelineClipCommandExecutor` owns all graph mutations.
- `TimelineClipObjectClipboardService` owns typed multi-track clipboard geometry.
- `TimelineClipSnapEngine` owns deterministic target selection.
- `TimelineClipUndoTransaction` owns affected graph, selection, transport, and leases.
- `WorkspaceView` translates user intent into typed commands and publishes results.

No renderer or AppKit overlay may mutate the graph. No clip command may derive its
target from presentation geometry after mouse-down; it must use stable track and clip
identities captured by hit testing.

## Shipping Surface

The shipping interaction surface includes multi-select, cross-track move,
Option-duplicate, marquee selection, Shift range selection, typed copy/cut/paste,
keyboard navigation and frame nudging, clip-edge/playhead/loop snapping, trim, gain,
fade, mute, lock, grouping, repeat, touching-clip crossfade, and source-preserving
replacement.

Advanced workflows have domain contracts but require a dedicated product pass before
being presented as shipping UI: pointer slip editing, editable crossfade curves,
ripple and roll tools, consolidate/bounce rendering, relink and source-replacement
dialogs, color/property inspector controls, loop handles, and take-lane comping.

## Performance Contract

Drag, trim, fade, gain, marquee, and snap previews are presentation-only until mouse
up. They must not rebuild waveform data, publish playback graphs, write projects,
layout transcripts, or create undo entries per frame. Commit is one typed transaction.

## Test Contract

Every editing-domain workflow requires deterministic unit coverage. User-facing clip
workflows also belong in `ClipGraphCutoverSmokeHarness`; frame-sensitive pointer work
belongs in the interaction replay and product bar. The 1,000-clip edit/undo workload
is the minimum scale regression fixture.
