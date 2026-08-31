# jb-p1lot plugin

Install the host and device bridge, then register this plugin:

```sh
jb-p1lot setup --all --device <udid> --ssh-host <device-address>
codex plugin marketplace add https://github.com/castdrian/jb-p1lot --ref main
codex plugin add jb-p1lot@adrian
```

The plugin starts the `jb-p1lot` MCP server over stdio and loads the bundled
`jb-p1lot` skill. Pairing is explicit and stored identities are
revocable from the device control app.
