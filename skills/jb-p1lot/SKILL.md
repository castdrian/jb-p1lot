---
name: jb-p1lot
description: Use when operating a paired rootless jailbroken iOS device through jb-p1lot for tweak development, UI automation, debugging, diagnostics, screen capture, package deployment, or userspace-only recovery.
---

# jb-p1lot

Use the `jb-p1lot` MCP server or the `jb-p1lot` CLI. Discover devices
first and pass an exact UDID whenever more than one paired device exists.

Read the focused references for [discovery](references/discovery.md),
[UI](references/ui.md), [tweak cycles](references/tweak-cycle.md),
[debugging](references/debugging.md), and [recovery](references/recovery.md).

The bridge uses mutually authenticated TLS 1.3 on WiFi and prefers USBMux
when USB is present. Pairing grants root authority to the paired host. Keep
outputs bounded and use artifact paths for large data. Accessibility node IDs
expire after the snapshot frame that created them.

Every reboot request is userspace-only. `device_action` values `reboot`,
`userspace_reboot`, `respring`, and `sbreload` converge on Dopamine's
userspace restart path. Hardware/full reboot requests are rejected.
