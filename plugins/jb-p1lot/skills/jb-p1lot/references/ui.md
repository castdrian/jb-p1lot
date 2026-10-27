# Visual and semantic UI

Use `ui_snapshot` first. It returns the visible accessibility elements of the
frontmost app, or of `--application <bundle id>`, with labels, values, hints,
frames, activation points, and traits; `--includeSpringBoard true` adds status
bar and overlay elements. Node IDs are valid only with the returned `frameId`.
Act on a node with `ui_action --frameId <id> --nodeId n3`, or skip the
snapshot with `ui_action --selector label=Settings`. Selectors match a label,
value, or hint substring, or an exact `label=`, `value=`, `hint=`, or
`trait=button` field. `ui_wait --selector <selector>` polls until a match
appears, or disappears with `--absent true`.

Use `screen_capture` to verify visual state and `ui_action` with normalized
coordinates or screen points when semantic nodes are unavailable. The visual
path remains independent of XCTest/WDA and works for SpringBoard surfaces.
Use HID actions for taps, long presses, drags, swipes, multitouch, Unicode
text, hardware buttons, display control, and system gestures. Use `screen_off`
or `screen_on` to black out or restore the display without locking the device;
the same actions are available through `device_action`, and the display is
blacked out by default (see [health.md](health.md)). Pass `--unlock true` to
wake and unlock the device before a tap, swipe, or text action. Swipes and
drags take `--points`, `--durationMs`, and `--easing linear|ease_in|ease_out|ease_in_out`
and are sampled every 8 ms along the whole path. Buttons are `home`, `lock`,
`unlock`, `volume_up`, `volume_down`, and `mute`. Protected display
layers are reported as unavailable. A button action can use `repeat` and
`intervalMs` for a hardware-button sequence.
