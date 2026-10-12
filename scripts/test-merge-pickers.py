#!/usr/bin/env python3
"""Run the Merge picker receiver through the shared app-object cache."""
from pathlib import Path
import subprocess
import sys
root = Path(__file__).resolve().parent.parent
subprocess.run([sys.executable, str(root / 'scripts/test-native-reference-batch.py'), '--only', 'merge-pickers', *sys.argv[1:]], cwd=root, check=True)
