# Debugging backends

Use `log_query` for scoped unified logs, `crash_manage` for crash reports, and
`diagnostics_collect` for sysdiagnose. Use `metrics_stream` for bounded CPU,
memory, graphics, energy, and network samples.

Use `debug_session` when source symbols, breakpoints, debugserver, LLDB
commands, memory access, or process launch/attach semantics are needed. Use
`frida_session` for dynamic instrumentation and script-driven hooks. Use
`network_capture` for a bounded BPF-filtered PCAP artifact and inspect it on
the host. The setup command provisions matching official Frida and Procursus
components; Apple's debugserver is consumed from mounted developer services.
