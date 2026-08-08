# Soundtime Automation Behavior Contract

Automation is parameter state over canonical timeline frames. The following rules are product contracts.

## Ownership

- Track automation stays at project time when clips move.
- Clip automation follows its clip through moves, duplicates, splits, trims, and cross-track moves.
- Plugin automation is bound to stable track, plugin-instance, and parameter identifiers. Unknown lanes remain persisted but disabled.
- Master automation is project-global.

## Values

- Lanes store normalized values in `0...1`; parameter descriptors own conversion, formatting, and smoothing.
- Track Volume is an absolute fader value using Soundtime's existing squared perceptual law. It is not multiplied by the static fader a second time.
- Track Pan is bipolar: `0 = L100`, `0.5 = C`, and `1 = R100`.
- Mute is stepped and uses a short de-click transition.
- Before the first point, the first point's value is held. After the last point, the last point's value is held.
- A disabled or unavailable lane preserves its data and yields the parameter's static value.

## Editing

- Clicking a point selects it. Deletion is explicit through Delete, a menu command, or a context menu.
- Command-click toggles selection; Shift-click extends an ordered range; marquee selection may select many points.
- A multi-point drag is one command and one undo transaction.
- Two points may not occupy the same owner, parameter, and frame. A command must reject or deterministically replace the collision before publication.
- Curve values belong to the segment leaving a point. Linear is the persisted default.
- Ripple insertion/deletion transforms affected track automation in timeline time. Clip automation follows the corresponding clip edit.

## Publication

- Realtime playback and export consume one immutable snapshot containing clip, automation, and binding revisions.
- Continuous parameters are smoothed according to their descriptor; stepped values change at a deterministic sample with de-clicking where audible.
- The audio callback performs no allocation, locking, logging, filesystem access, graph traversal, or parameter formatting.

## Interaction Performance

- Pointer previews are render-only until commit.
- One display refresh samples pointer state; mouse event frequency does not determine visual smoothness.
- Only visible lanes submit curve and point instances.
- Hover, selection, preview, and playhead energy are uniform- or instance-driven and do not rebuild persistent geometry.
