#!/usr/bin/env python3
"""Run branch-description acceptance through the cached owned native batch."""
import subprocess
import sys
from pathlib import Path
subprocess.run([sys.executable, str(Path(__file__).with_name('test-native-reference-batch.py')), '--only', 'description', *sys.argv[1:]], check=True)
