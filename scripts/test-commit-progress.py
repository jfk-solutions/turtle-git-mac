#!/usr/bin/env python3
"""Commit progress receiver linked to the built Debug app object cache."""
from pathlib import Path
import subprocess
import sys
root = Path(__file__).resolve().parent.parent
subprocess.run([sys.executable, str(root / 'scripts/test-native-reference-batch.py'), '--only', 'commit-progress', *sys.argv[1:]], cwd=root, check=True)
