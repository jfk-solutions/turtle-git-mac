#!/usr/bin/env python3
"""Run the ranges RefLog fixture using the shared compiled receiver."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
subprocess.run([sys.executable, str(root / 'scripts/test-native-reflog-batch.py'),
                '--only', 'ranges', *sys.argv[1:]], check=True)
