#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
configuration="${1:-debug}"
if [ "$configuration" != debug ] && [ "$configuration" != release ]; then
    echo 'Usage: bash scripts/build-app.sh [debug|release]' >&2
    exit 2
fi
bash scripts/build-icon.sh
bash scripts/swift.sh build --configuration "$configuration" --product PathDeck
binary_dir="$(bash scripts/swift.sh build --configuration "$configuration" --show-bin-path)"
app="$project_root/build/$configuration/PathDeck.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/PathDeck" "$app/Contents/MacOS/PathDeck"
cp PathDeck/Resources/Info.plist "$app/Contents/Info.plist"
cp PathDeck/Resources/PathDeck.icns "$app/Contents/Resources/PathDeck.icns"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
# Local ad-hoc signing needs no Apple account or distribution certificate.
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
/usr/bin/touch "$app"
echo "Built: $app"

