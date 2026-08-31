#!/usr/bin/env python3
import json
import pathlib
import sys

plugin = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "plugins/jb-p1lot")
manifest_path = plugin / ".codex-plugin" / "plugin.json"
manifest = json.loads(manifest_path.read_text())
required = ["name", "version", "description", "author", "skills", "mcpServers", "interface"]
missing = [key for key in required if key not in manifest]
if missing:
    raise SystemExit("missing manifest fields: " + ", ".join(missing))
if manifest["name"] != plugin.name:
    raise SystemExit("manifest name does not match plugin directory")
if not (plugin / ".mcp.json").is_file():
    raise SystemExit("missing .mcp.json")
skill_root = plugin / "skills"
if not list(skill_root.glob("*/SKILL.md")):
    raise SystemExit("missing bundled skill")
print("plugin valid")
