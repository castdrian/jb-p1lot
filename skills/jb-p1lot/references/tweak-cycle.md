# Tweak cycle

Use `tweak_build` to run Theos with `gmake` and select the newest rootless
package. `tweak_deploy` performs a scoped reload and heartbeat check.
`tweak_cycle` combines build, install, requested process reload, logs, crash
detection, and rollback while retaining the previous package.
