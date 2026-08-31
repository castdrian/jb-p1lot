#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
host_bin="${GOBIN:-$(go env GOPATH)/bin}/jb-p1lot"
mkdir -p "$(dirname "$host_bin")"
go build -trimpath -ldflags "-s -w" -o "$host_bin" ./cmd/jb-p1lot
if command -v codex >/dev/null 2>&1; then
    codex plugin marketplace add https://github.com/castdrian/jb-p1lot --ref main || true
    codex plugin add jb-p1lot@adrian || true
fi
if [ "${JBP1LOT_SETUP:-0}" = "1" ]; then
    jb-p1lot setup --all "$@"
fi
printf '%s\n' "jb-p1lot host installed; set JBP1LOT_SETUP=1 to run full provisioning"
