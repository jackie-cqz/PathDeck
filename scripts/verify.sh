#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mkdir -p build/validation
python3 scripts/generate-project.py --check
/usr/bin/plutil -lint PathDeck.xcodeproj/project.pbxproj PathDeck/Resources/Info.plist
bash -n scripts/swift.sh scripts/build-app.sh scripts/build-icon.sh scripts/verify.sh scripts/performance.sh
bash scripts/swift.sh test 2>&1 | tee build/validation/core-tests.log
bash scripts/build-app.sh debug 2>&1 | tee build/validation/build-app.log
# Requires an interactive macOS login session; opens then terminates its window.
smoke_report_dir="$(mktemp -d "${TMPDIR:-/tmp}/PathDeck-verify.XXXXXX")"
trap 'rm -rf "$smoke_report_dir"' EXIT
/usr/bin/open -n -W --stdout "$smoke_report_dir/report.json" \
    --stderr "$smoke_report_dir/stderr.log" \
    "$project_root/build/debug/PathDeck.app" --args --smoke-test
cp "$smoke_report_dir/report.json" build/validation/smoke-test.json
cp "$smoke_report_dir/stderr.log" build/validation/smoke-stderr.log
python3 - <<'PY'
import json
with open('build/validation/smoke-test.json') as report:
    result = json.load(report)
print(json.dumps(result, ensure_ascii=False, indent=2))
raise SystemExit(0 if result['passed'] else 1)
PY
echo 'PathDeck command-line validation passed. See build/validation/.'
