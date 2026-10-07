#!/bin/bash
# Native transport check; no GUI app or Finder instance is launched.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c debug
provider_build_path="$(swift build -c debug --show-bin-path)"
provider_check_directory="$(mktemp -d -t TurtleGitProviderCheck)"
trap 'rm -rf "$provider_check_directory"' EXIT
swiftc -parse-as-library -I "$provider_build_path/Modules" Sources/TurtleGitMac/RepositoryBrowserDrag.swift scripts/verify-browser-item-provider.swift "$provider_build_path"/TurtleGitCore.build/*.o -o "$provider_check_directory/check"
python3 - "$provider_check_directory/check" <<'PYTHON'
import subprocess, sys
subprocess.run([sys.argv[1]], check=True, timeout=60)
PYTHON
