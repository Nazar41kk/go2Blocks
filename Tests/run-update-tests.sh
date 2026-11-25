#!/usr/bin/env bash
# Tests the update logic (Go2Blocks/UpdateManager.swift) on this Mac: builds some fake update
# feeds, serves them locally, compiles the manager with the tests and runs them. Needs swiftc.
set -euo pipefail
cd "$(dirname "$0")"
WORK="$(mktemp -d)"
trap 'kill "${SERVER:-0}" 2>/dev/null || true; rm -rf "$WORK"' EXIT
python3 - "$WORK/feed" <<'PY'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
def feed(name, files, min_shell=1, wrong_hash=None, extra=()):
    entries = []
    for path, data in files.items():
        target = root / name / "files" / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        sha = hashlib.sha256(data).hexdigest() if path != wrong_hash else "0" * 64
        entries.append({"path": path, "sha256": sha, "size": len(data)})
    entries += list(extra)
    (root / name / "manifest.json").write_text(json.dumps({"version": name, "minShell": min_shell, "files": entries}))
v1 = {"index.html": b"<html>v1</html>", "assets/a.js": b"same", "assets/b.js": b"new", "version.json": b'{"version":"v1"}'}
feed("v1", v1)
feed("v2-bad", v1, wrong_hash="assets/b.js")
feed("v3-newapp", v1, min_shell=99)
feed("v4-evil", v1, extra=[{"path": "../escape.txt", "sha256": "0" * 64, "size": 1}])
PY
PORT=$((20000 + RANDOM % 20000))
(cd "$WORK/feed" && python3 -m http.server "$PORT" >/dev/null 2>&1) & SERVER=$!
sleep 1
swiftc -parse-as-library ../Go2Blocks/UpdateManager.swift UpdateManagerTests.swift -o "$WORK/tests" 2>&1 | grep -v "^$" || true
"$WORK/tests" "$WORK/feed" "$PORT"
