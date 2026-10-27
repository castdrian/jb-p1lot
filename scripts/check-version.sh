#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
version=$(tr -d '[:space:]' < VERSION)
echo "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "VERSION is not semver: $version"; exit 1; }
if grep -n '^Version:' layout/DEBIAN/control device/resources/control; then
  echo "control files must not carry a Version line; the Makefile stamps it from VERSION"
  exit 1
fi
stray=$(git grep -n -E '"[0-9]+\.[0-9]+\.[0-9]+"' -- '*.go' '*.m' '*.x' '*.xm' | grep -v -E '_test\.go|go\.sum' || true)
if [ -n "$stray" ]; then
  echo "hard-coded version literals found; use VERSION:"
  echo "$stray"
  exit 1
fi
plugin_version=$(python3 -c 'import json;print(json.load(open("plugins/jb-p1lot/.codex-plugin/plugin.json"))["version"])')
[ "$plugin_version" = "$version" ] || { echo "plugin.json version $plugin_version does not match VERSION $version"; exit 1; }
if [ ! -L skills/jb-p1lot ] || [ "$(readlink skills/jb-p1lot)" != "../plugins/jb-p1lot/skills/jb-p1lot" ]; then
  echo "skills/jb-p1lot must be a symlink to the canonical plugin skill"
  exit 1
fi
latest=$(git tag --list 'v[0-9]*' | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
if [ -n "$latest" ]; then
  highest=$(printf '%s\n%s\n' "$latest" "$version" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
  if [ "$version" = "$latest" ] && git rev-parse -q --verify "refs/tags/v$version" >/dev/null && [ "$(git rev-list -n1 "v$version")" != "$(git rev-parse HEAD)" ]; then
    echo "VERSION $version is already released as v$version; bump it"
    exit 1
  fi
  if [ "$highest" != "$version" ]; then
    echo "VERSION $version is lower than the latest release v$latest"
    exit 1
  fi
fi
echo "version $version ok"
