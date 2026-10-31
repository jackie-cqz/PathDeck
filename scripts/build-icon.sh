#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
source_image="assets/branding/PathDeck-master.png"
iconset="build/branding/PathDeck.iconset"
icon_file="PathDeck/Resources/PathDeck.icns"
if [ ! -f "$source_image" ]; then
    echo "Missing approved icon master: $source_image" >&2
    exit 1
fi
mkdir -p "$iconset" "$(dirname "$icon_file")"
# The generated source is kept unchanged. sips only resamples for macOS icon slots.
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$source_image" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    /usr/bin/sips -z "$retina_size" "$retina_size" "$source_image" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$icon_file"
echo "Generated: $icon_file (16–1024 px)"
