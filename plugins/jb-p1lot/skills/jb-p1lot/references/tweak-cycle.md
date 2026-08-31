# Tweak cycle

Use `tweak_build` to run Theos with `gmake`, select the newest package, and
retain a previous package for rollback. Use `tweak_deploy` for a scoped reload
and heartbeat verification. Use `tweak_cycle` for build, install, process
reload, scoped logs, crash detection, and automatic rollback.

Prefer reloading only requested injected processes. Use `sbreload` when the
SpringBoard target is requested. After a failure, collect `log_query` and
`crash_manage` artifacts before rolling back so the failing package and
heartbeat state remain attributable.
