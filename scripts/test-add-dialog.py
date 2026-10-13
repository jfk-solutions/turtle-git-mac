#!/usr/bin/env python3
"""Run all existing Add selector assertions through the cached owned batch."""
import subprocess
import sys
from pathlib import Path
subprocess.run([sys.executable, str(Path(__file__).with_name('test-native-reference-batch.py')), '--only', 'add-dialog', *sys.argv[1:]], check=True)
