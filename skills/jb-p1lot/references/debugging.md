# Debugging backends

Use `log_query`, `crash_manage`, and `diagnostics_collect` for logs, crashes,
and sysdiagnose. Use `metrics_stream` for bounded performance samples.

Use `debug_session` for LLDB/debugserver symbols, breakpoints, commands,
memory, launch, and attach. Use `frida_session` for dynamic instrumentation.
Use `network_capture` for a bounded BPF-filtered PCAP artifact. Setup uses
matching official Frida versions, Procursus tcpdump, WDA, and mounted Apple
developer services without redistributing debugserver.
