#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
action="${1:-build}"
if [ "$#" -gt 0 ]; then shift; fi
mkdir -p .build/cache .build/config .build/security .build/ModuleCache
export CLANG_MODULE_CACHE_PATH="$project_root/.build/ModuleCache"
extra_args=()
if [ "$action" = test ]; then
    # These tests use Swift Testing, which ships with current Command Line Tools.
    extra_args+=(--disable-xctest)
    # Swift 6.4's default swiftbuild backend may omit this bundled macro plugin.
    # Resolve from the selected compiler instead of hard-coding a machine path.
    compiler="$(xcrun --find swiftc)"
    toolchain_usr="$(cd "$(dirname "$compiler")/.." && pwd)"
    testing_plugin="$toolchain_usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
    if [ -f "$testing_plugin" ]; then
        extra_args+=(-Xswiftc -load-plugin-library -Xswiftc "$testing_plugin")
    fi
fi
exec swift "$action" \
    --cache-path "$project_root/.build/cache" \
    --config-path "$project_root/.build/config" \
    --security-path "$project_root/.build/security" \
    --scratch-path "$project_root/.build" \
    --manifest-cache local ${extra_args[@]+"${extra_args[@]}"} "$@"

