# Visual and semantic UI

Use `ui_snapshot` first when WDA/XCTest accessibility is available. Node IDs
are scoped to the returned frame and expire after a new snapshot. Prefer role,
label, value, state, and bounds selectors.

Use `screen_capture` plus normalized coordinates or screen points when semantic
nodes are unavailable. `ui_action` supports HID taps, long presses, drags,
swipes, multitouch, Unicode text, hardware buttons, display control, and system
gestures. Use `screen_off` or `screen_on` to darken or restore the display
without locking the device. The same actions are available through
`device_action`. A button action can use `repeat` and `intervalMs` for a
hardware-button sequence. Protected display layers are reported as unavailable.
