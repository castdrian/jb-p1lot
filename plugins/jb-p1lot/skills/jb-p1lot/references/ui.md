# Visual and semantic UI

Use `ui_snapshot` first when accessibility or WDA is available. Save its
`frameId` and node IDs only for the next `ui_action`; IDs expire after a new
snapshot. Prefer role, label, value, state, and bounds selectors over guessed
coordinates.

Use `screen_capture` to verify visual state and `ui_action` with normalized
coordinates or screen points when semantic nodes are unavailable. The visual
path remains independent of XCTest/WDA and works for SpringBoard surfaces.
Use HID actions for taps, long presses, drags, swipes, multitouch, Unicode
text, hardware buttons, display control, and system gestures. Use `screen_off`
or `screen_on` to darken or restore the display without locking the device;
the same actions are available through `device_action`. Protected display
layers are reported as unavailable. A button action can use `repeat` and
`intervalMs` for a hardware-button sequence.
