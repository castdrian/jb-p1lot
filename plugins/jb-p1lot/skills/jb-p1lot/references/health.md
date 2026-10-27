# Health, charging, and display

`device_health` reports battery charge, capacity, health, cycle count,
temperature, voltage, current, adapter wattage, charge inhibition, thermal
state, memory pressure, free storage, and uptime. Use `--action history` for
one-minute samples from the last 24 hours and `--action alerts` for memory
pressure, low memory, low storage, jetsam, kernel panic, reboot, temperature,
and charge-control alerts. Pass `--clear true` with `alerts` to reset them.

The daemon holds the battery between `chargeLimit.low` and `chargeLimit.high`
(50 and 80 percent by default) by inhibiting charging through the SMC while
the adapter keeps powering the device. Thermal mitigation pauses charging at
`thermal.pauseChargingC`, throttles performance at `thermal.throttleC`, blacks
out the display at `thermal.dimC`, and releases throttling and the charge
pause below `thermal.resumeC`. Change any of these with
`device_health --action configure`, for example
`--chargeLimit '{"high":70}'` or `--chargeMode inhibit|allow|auto`. Removing
the package or stopping the daemon releases every power control.

The display is blacked out by default: the panel is powered down without
locking the device, so taps, accessibility, and `screen_capture` keep working.
A physical triple press of the home button toggles it, as does volume up, volume down, volume up in quick succession on devices without one, and `ui_action` or
`device_action` with `blackout_off`, `blackout_on` (or `screen_off`), or
`blackout_toggle` sets it remotely. `screen_on` only wakes SpringBoard and
leaves the blackout as it is. The choice persists across daemon restarts.
