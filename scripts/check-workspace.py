#!/usr/bin/env python3
"""Launch two isolated app processes and verify the on-disk workspace handoff."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

project = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else project / "build/release/PathDeck.app"
reports = project / "build/validation"
reports.mkdir(parents=True, exist_ok=True)
fixture = None


def owned_fixture(path):
    root = Path(path).resolve()
    assert root.parent == Path(tempfile.gettempdir()).resolve()
    assert root.name.startswith("PathDeck-smoke-")
    assert (root / ".workspace-qa").read_text() == "PathDeck workspace QA"
    return root


try:
    with tempfile.TemporaryDirectory(prefix="PathDeck-Session-", dir="/private/tmp") as directory:
        qa = Path(directory)
        environment = dict(os.environ, PATHDECK_TEST_PREFERENCES=str(qa / "preferences.json"))

        def launch(mode, name):
            output, errors = qa / f"{name}.json", qa / f"{name}.stderr.log"
            subprocess.run(["/usr/bin/open", "-n", "-W", "--stdout", str(output), "--stderr", str(errors), str(app), "--args", mode], env=environment, check=True, timeout=120)
            shutil.copy2(output, reports / output.name)
            shutil.copy2(errors, reports / errors.name)
            result = json.loads(output.read_text())
            failed = [key for key, passed in result["checks"].items() if not passed]
            print(f"{name}: {len(result['checks'])} checks; failed={failed}", flush=True)
            return result

        producer = launch("--workspace-save-test", "workspace-producer")
        if "fixture" in producer:
            fixture = owned_fixture(producer["fixture"])
        assert producer["passed"] and fixture is not None
        shutil.copy2(qa / "preferences.json", reports / "workspace-before-restart.json")
        # The closed app cannot observe these changes; selection must be restored by identity.
        (fixture / "Empty").rename(fixture / "Empty-moved")
        (fixture / "中文 Folder/hello.txt").rename(fixture / "中文 Folder/hello-renamed.txt")
        replacement = fixture / "Session C/replace.session.txt"
        replacement.rename(fixture / "kept-replaced-original.txt")
        replacement.write_text("replacement must not be selected")
        consumer = launch("--workspace-load-test", "workspace-consumer")
        shutil.copy2(qa / "preferences.json", reports / "workspace-after-restart.json")
        assert consumer["passed"]
finally:
    if fixture is not None:
        shutil.rmtree(owned_fixture(fixture))
