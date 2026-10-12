#!/usr/bin/env python3
"""Run owned Stash Apply/Pop checks through the cached native reference receiver."""
from pathlib import Path
import subprocess
import sys
root = Path(__file__).resolve().parent.parent
raise SystemExit(subprocess.call([sys.executable, str(root / 'scripts/test-native-reference-batch.py'), '--only', 'stash-restore', *sys.argv[1:]], cwd=root))
