#!/usr/bin/env bash
# Makes the Xcode project (and, inside the full Go2 Blocks project, rebuilds the editor first).
#   Inside the full project (../ui exists): builds the editor, copies it into the app, refreshes the
#   icon and credits, then runs XcodeGen.
#   As a standalone repo (only this folder): uses the editor already in Go2Blocks/web, then XcodeGen.
set -euo pipefail
cd "$(dirname "$0")"
if [ -d ../ui ]; then
  (cd ../ui && { [ -d node_modules ] || npm install --no-audit --no-fund; } && npm run build >/dev/null)
  ../bridge/.venv/bin/python ../scripts/make-ios-icon.py 2>/dev/null || echo "(icon kept as it was: bridge/.venv with Pillow not found)"
  rm -rf Go2Blocks/web && cp -R ../ui/dist Go2Blocks/web
  cp ../ui/src/sounds/CREDITS.md SOUND-CREDITS.md
else
  echo "(standalone: using the editor already in Go2Blocks/web)"
fi
[ -f Go2Blocks/web/index.html ] || { echo "Go2Blocks/web/index.html is missing: build the editor in the full project first."; exit 1; }
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
xcodegen generate
echo "Open Go2Blocks.xcodeproj in Xcode, pick your iPad, set your Team under Signing, and press Run."
