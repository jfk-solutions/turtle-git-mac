#!/usr/bin/env python3
"""Run the owned native SSH family through the cached app-object receiver."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
subprocess.run([sys.executable, str(root / 'scripts/test-native-reference-batch.py'),
                '--only', 'ssh-coordinator', *sys.argv[1:]], cwd=root, check=True)
