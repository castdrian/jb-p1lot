#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
icon_tool="${ICTOOL_PATH:-/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool}"
if [ ! -x "$icon_tool" ]; then
    printf '%s\n' "Icon Composer ictool is required" >&2
    exit 1
fi
if ! command -v sips >/dev/null 2>&1; then
    printf '%s\n' "sips is required for the flat fallback" >&2
    exit 1
fi
mkdir -p "$root/assets/icons/flat" "$root/device/resources"
"$icon_tool" "$root/assets/icons/jb-p1lot.icon" --export-image --output-file "$root/assets/icons/jb-p1lot-liquid-glass.png" --platform iOS --rendition Default --width 1024 --height 1024 --scale 1
sips -s format png "$root/assets/icons/jb-p1lot-flat.svg" --out "$root/assets/icons/flat/jb-p1lot-flat.png" >/dev/null
sips -z 1024 1024 "$root/assets/icons/jb-p1lot-liquid-glass.png" --out "$root/device/resources/AppIcon.png" >/dev/null
sips -z 180 180 "$root/assets/icons/jb-p1lot-liquid-glass.png" --out "$root/device/resources/AppIcon60x60@3x.png" >/dev/null
sips -z 120 120 "$root/assets/icons/jb-p1lot-liquid-glass.png" --out "$root/device/resources/AppIcon60x60@2x.png" >/dev/null
sips -z 152 152 "$root/assets/icons/jb-p1lot-liquid-glass.png" --out "$root/device/resources/AppIcon76x76@2x.png" >/dev/null
sips -z 256 256 "$root/assets/icons/flat/jb-p1lot-flat.png" --out "$root/assets/icons/flat/jb-p1lot-tweak.png" >/dev/null
cp "$root/assets/icons/flat/jb-p1lot-tweak.png" "$root/layout/icon.png"
