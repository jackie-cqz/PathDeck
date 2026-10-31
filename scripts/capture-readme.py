#!/usr/bin/env python3
"""Build the actual AppKit views in an isolated app and export README images."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
build = root / "build/ReadmeCapture"
app = build / "PathDeck Showcase.app"
binary = app / "Contents/MacOS/PathDeckShowcase"
binary.parent.mkdir(parents=True, exist_ok=True)
sources = sorted(str(p) for p in (root / "PathDeck").rglob("*.swift") if p.name != "PathDeckApplication.swift")
with (build / "compile.log").open("w") as log:
    subprocess.run(["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-module-name", "PathDeckShowcase", *sources, str(root / "scripts/capture-readme.swift"), "-o", str(binary)], stdout=log, stderr=subprocess.STDOUT, check=True)
info = {"CFBundleIdentifier": "local.pathdeck.showcase", "CFBundleExecutable": binary.name, "CFBundleName": "PathDeck Showcase", "CFBundlePackageType": "APPL", "NSHighResolutionCapable": True, "LSMinimumSystemVersion": "14.0"}
(app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True)
with tempfile.TemporaryDirectory(prefix="PathDeck-Readme-", dir="/private/tmp") as directory:
    report = Path(directory) / "report.log"
    errors = Path(directory) / "stderr.log"
    environment = dict(os.environ, PATHDECK_README_OUTPUT=str(root / "docs/images/showcase"))
    subprocess.run(["/usr/bin/open", "-n", "-W", "--stdout", str(report), "--stderr", str(errors), str(app), "--args", "--smoke-test"], env=environment, check=True, timeout=120)
    result = report.read_text()
    print(result)
    (build / "stderr.log").write_text(errors.read_text())
    assert result.startswith("Exported six native AppKit screenshots"), "Capture app did not complete; see build/ReadmeCapture/stderr.log"
names = ["overview-light", "overview-dark", "path-entry", "name-filter", "inline-rename", "file-properties"]
assert all((root / f"docs/images/showcase/{name}.png").is_file() for name in names)
print(json.dumps({"screenshots": names, "count": len(names)}))
