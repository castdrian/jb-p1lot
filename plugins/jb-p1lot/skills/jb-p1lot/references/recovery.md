# Recovery

When SpringBoard is unhealthy, first collect logs and crash artifacts, then
use `device_action` with `sbreload` or `userspace_reboot`. The bridge daemon
survives SpringBoard reinjection and reconnects the agent automatically.

If the tweak cycle detects a crash, let it disable or roll back the newest
package before retrying. Dopamine recovery assumes a passcode-free device and
uses CoreDevice, WDA, and HID to relaunch Dopamine and reconnect. A hardware
reboot is intentionally not exposed by this bridge.
