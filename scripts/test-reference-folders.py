#!/usr/bin/env python3
"""Focused reference receiver using the shared Debug-object compilation cache."""
from pathlib import Path
import subprocess
import sys
root = Path(__file__).resolve().parent.parent
subprocess.run([sys.executable, str(root / 'scripts/test-native-reference-batch.py'),
                '--only', 'folders', *sys.argv[1:]], cwd=root, check=True)
