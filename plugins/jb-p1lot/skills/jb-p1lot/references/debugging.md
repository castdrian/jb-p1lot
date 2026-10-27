# Debugging backends

Use `log_query` for unified logs. Without `--follow` it reads history from
`--since` (such as `30s`, `10m`, `2h`, an ISO date, or epoch milliseconds);
with `--follow true` it streams live entries for `--durationMs`. Filter with
`--process <name or pid>` and `--predicate` over `process`,
`processIdentifier`, `subsystem`, `category`, `sender`, `messageType`, and
`eventMessage`. `--limit` bounds the returned lines.

Use `metrics_stream --durationMs --intervalMs` for samples of per-core CPU,
memory, GPU utilization, battery power, per-interface network rates, and, with
`--process`, the CPU, footprint, energy, and disk rates of one process.
Use `crash_manage` for crash reports and `diagnostics_collect` for sysdiagnose.

Use `debug_session` to attach debugserver with `--pid`, `--process`, or
`--waitFor`, or to launch an executable with `--path`. The daemon provisions a
re-signed copy of Apple's debugserver from the mounted developer disk image
and forwards its port over USB; connect with the returned `connect` command,
or pass `--command` (repeatable) to run host lldb in batch mode and return its
output. End lldb commands with `detach` to leave the target running; stopping a
session that is still attached terminates the target.

Use `frida_session` to start frida-server and forward it over USB; pass
`--script` with `--process`, `--pid`, or `--bundleId` to run a host frida
script. It needs the `re.frida.server` package on the device.
`port_forward --action start|list|stop` manages other USB forwards to device
loopback ports. Use `network_capture` for a bounded BPF-filtered PCAP artifact.
