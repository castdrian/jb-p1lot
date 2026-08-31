# jb-p1lot

Rootless iOS jailbreak development bridge with a Go CLI, stdio MCP server,
Theos package, SpringBoard screen/HID agent, and small on-device control app.

```sh
git clone https://github.com/castdrian/jb-p1lot.git
cd jb-p1lot
./scripts/bootstrap.sh
jb-p1lot setup --all --device <udid> --ssh-host <host> --ssh-port <port>
```

Install the Codex integration with:

```sh
codex plugin marketplace add https://github.com/castdrian/jb-p1lot --ref main
codex plugin add jb-p1lot@adrian
```

If this saves you time, [sponsor the project](https://github.com/sponsors/castdrian).

<details>
<summary>Capabilities</summary>

Discovery, root shell/files, screenshots and H.264 streams, accessibility and
HID input, app/process/package control, logs/crashes/sysdiagnose, metrics,
PCAP, LLDB, Frida, tweak build/deploy/rollback, and long-running sessions are
exposed as both CLI commands and MCP tools.

</details>

<details>
<summary>Transport and recovery</summary>

The device daemon listens on TCP 5912, advertises `_jb-p1lot._tcp`, and requires
TLS 1.3 mutual authentication. USBMux is preferred when USB is connected and
encrypted WiFi remains available after disconnect. Pairing grants root
authority to the paired host; the control app can revoke, rotate, or restart
the bridge.

Every reboot operation is userspace-only and maps to Dopamine's userspace
restart path. Hardware/full reboot requests are rejected so the jailbreak is
not intentionally lost.

</details>

<details>
<summary>Development</summary>

```sh
go test ./...
gmake package FINALPACKAGE=1
python3 scripts/validate_plugin.py plugins/jb-p1lot
python3 scripts/validate_skill.py skills/jb-p1lot
```

See `skills/jb-p1lot` for focused routing guidance. See
`THIRD_PARTY_NOTICES.md` for ScreenMirror and MCP SDK attribution.

</details>
