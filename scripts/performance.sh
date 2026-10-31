#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mkdir -p build/validation
bash scripts/build-app.sh release >build/validation/release-build.log 2>&1
{
    /usr/sbin/sysctl -n hw.model hw.memsize
    /usr/bin/sw_vers
    xcrun swift --version
    /usr/sbin/diskutil info / | /usr/bin/awk '/File System Personality|Solid State/ {print}'
} >build/validation/performance-environment.txt
build/release/PathDeck.app/Contents/MacOS/PathDeck --performance-test \
    2>build/validation/performance-stderr.log | tee build/validation/performance.json
