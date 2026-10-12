#!/usr/bin/env python3
"""Email settings receiver using the shared native compilation cache.

Compile the actual app/settings dependencies rather than an incomplete source subset.
Preferences and Security calls remain private/simulated in the receiver.
"""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
subprocess.run([sys.executable, str(root / 'scripts/test-native-lfs-mail-batch.py'),
                '--email-only'], cwd=root, check=True)
