#!/usr/bin/env python3
"""Run owned stash-save-progress checks through the cached native receiver."""
from pathlib import Path
import subprocess
import sys
root = Path(__file__).resolve().parent.parent
raise SystemExit(subprocess.call([sys.executable, str(root / 'scripts/test-native-reference-batch.py'), '--only', 'stash-save-progress', *sys.argv[1:]], cwd=root))
