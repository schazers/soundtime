# Mixer Behavior Contract

The mixer is a second presentation of the canonical project session. It does
not own track mix values, automation lanes, ordering, or audio meter truth.

## Ordering And Identity

- Channel strips use clip-graph track order and stable track UUIDs.
- Reorder, insert, delete, save, and reopen preserve identity.
- The master strip is pinned after all project channels and never scrolls away.

## Signal And Meter Point

Track meters represent the exact contribution mixed into the master bus after
clip gain/fades, track mute/solo, volume automation, the static fader, and pan.
They are measured before master gain or future master-bus processing.

## Controls

- Volume storage remains linear gain; the fader presents -infinity through
  +12 dB with a 0 dB detent.
- Pan uses the existing -1...1 audible domain and the shared pan-knob control.
- Timeline and mixer controls call the same coordinator and create one undo
  transaction per gesture.
- Double-click or Command-click resets fader and pan to unity/center.
- Plain X toggles the mixer unless a text editor owns keyboard input. Command-X
  remains Cut.

## Automation

- Read follows automation and rejects direct persistent writes.
- Touch writes only while the control is held, then returns to the lane.
- Latch continues the last touched value until transport stops.
- Write records control values for the entire active playback interval.
- A control under the pointer never fights a motorized automation update.

## Realtime Safety

- Audio-thread metering uses fixed storage and performs no allocation, locking,
  logging, Objective-C messaging, or filesystem access.
- Meter packets carry graph revision and runtime slot; stale packets are
  discarded after graph replacement.
- UI metering is demand-driven and batched. Closing the mixer disables detailed
  track metering without affecting the always-on master meter.
