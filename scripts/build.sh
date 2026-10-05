#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/build-editorconfig-runtime.py
if command -v xcodegen >/dev/null; then xcodegen generate; fi
xcodebuild -quiet -project TurtleGitMac.xcodeproj -scheme TurtleGitMac \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
printf '%s\n' "Built: $(pwd)/build/Build/Products/Debug/TurtleGitMac.app"
