#!/usr/bin/env python3
import pathlib
import sys

skill = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "skills/jb-p1lot")
path = skill / "SKILL.md"
text = path.read_text()
if not text.startswith("---\n") or "name:" not in text or "description:" not in text:
    raise SystemExit("skill frontmatter is incomplete")
for reference in ["discovery.md", "ui.md", "tweak-cycle.md", "debugging.md", "recovery.md"]:
    if not (skill / "references" / reference).is_file():
        raise SystemExit("missing reference: " + reference)
print("skill valid")
