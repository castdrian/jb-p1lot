# Recovery

Collect logs and crash artifacts before recovery. Use `device_action` with
`sbreload` or `userspace_reboot`; the root daemon remains alive while
SpringBoard is reinjected and reconnects the agent. Tweak cycles can disable
or roll back a crashing package. Dopamine relaunch and re-jailbreak assumes a
passcode-free device and uses CoreDevice, WDA, and HID. Hardware reboot is not
exposed.
