#!/usr/bin/env python3
"""Compile the shared Xcode-source/import branch without running Xcode."""
from pathlib import Path
import platform
import subprocess

root = Path(__file__).resolve().parent.parent
output = root / "build/validation/native"
output.mkdir(parents=True, exist_ok=True)
cache = root / ".build/NativeModuleCache"
cache.mkdir(parents=True, exist_ok=True)
compiler = Path(subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip())
common = [str(compiler), "-swift-version", "6", "-module-cache-path", str(cache),
          "-target", f"{platform.machine()}-apple-macosx14.0"]
subprocess.run(common + ["-parse-as-library", "-enable-testing", "-module-name", "PathDeck",
                        "-emit-module", "-emit-module-path", str(output / "PathDeck.swiftmodule"),
                        "-emit-library", "-o", str(output / "libPathDeck.dylib")]
               + [str(p) for p in sorted((root / "PathDeck").rglob("*.swift"))], check=True, cwd=root)
plugin = compiler.parent.parent / "lib/swift/host/plugins/testing/libTestingMacros.dylib"
macro = ["-load-plugin-library", str(plugin)] if plugin.is_file() else []
framework_candidates = [compiler.parent.parent.parent / "Library/Developer/Frameworks"]
if not any((path / "Testing.framework").is_dir() for path in framework_candidates):
    sdk_platform = Path(subprocess.check_output(["xcrun", "--show-sdk-platform-path"], text=True).strip())
    framework_candidates.append(sdk_platform / "Developer/Library/Frameworks")
frameworks = next(path for path in framework_candidates if (path / "Testing.framework").is_dir())
subprocess.run(common + macro + ["-typecheck", "-F", str(frameworks), "-I", str(output)]
               + [str(p) for p in sorted((root / "PathDeckTests").rglob("*.swift"))], check=True, cwd=root)
print("Native app module compiled; shared tests typechecked without SWIFT_PACKAGE.")
