---
name: jb-p1lot
description: Use when operating a paired rootless jailbroken iOS device through jb-p1lot for tweak development, UI automation, debugging, diagnostics, screen capture, package deployment, or userspace-only recovery.
---

# jb-p1lot

Use the `jb-p1lot` MCP server or the `jb-p1lot` CLI. Always discover
devices first and pass an exact UDID when more than one paired device exists.
Never infer a target from network order or an arbitrary first result.

## Routing

- Discovery and exact targeting: read [discovery.md](references/discovery.md).
- Visual and semantic UI control: read [ui.md](references/ui.md).
- Build, deploy, logs, and rollback: read [tweak-cycle.md](references/tweak-cycle.md).
- LLDB, Frida, and packet capture: read [debugging.md](references/debugging.md).
- SpringBoard recovery and Dopamine reconnect: read [recovery.md](references/recovery.md).

## Defaults

The bridge uses encrypted WiFi on TCP 5912 and prefers a USBMux tunnel when
USB is present. Pairing grants root authority to the paired host. Use bounded
outputs and artifact paths for large files. Accessibility node IDs are valid
only for the snapshot frame that returned them; refresh before acting when a
selector expires.

All reboot requests are userspace-only. Use `device_action` with `reboot`,
`userspace_reboot`, `respring`, or `sbreload`; these converge on Dopamine's
userspace restart path. Do not request a hardware/full reboot because the
bridge rejects it to preserve the jailbreak.
