#!/usr/bin/env python3
"""Run existing picker assertions through the cached owned batch."""
import subprocess
import sys
from pathlib import Path
subprocess.run([sys.executable, str(Path(__file__).with_name('test-native-reference-batch.py')), '--only', 'switch-pickers', *sys.argv[1:]], check=True)
