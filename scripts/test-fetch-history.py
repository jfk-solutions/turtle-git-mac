#!/usr/bin/env python3
"""Reuse the built-object receiver for Fetch/Pull history checks."""
from pathlib import Path
import subprocess
import sys
root = Path(__file__).resolve().parent.parent
subprocess.run([sys.executable, str(root/'scripts/test-native-reference-batch.py'), '--only', 'fetch-history', *sys.argv[1:]], cwd=root, check=True)
