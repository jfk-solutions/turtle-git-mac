#!/usr/bin/env python3
"""Run the three-pane source regression through cached, owned native receivers."""
import argparse
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
command = [sys.executable, str(root/'scripts/test-native-reference-batch.py'), '--only', 'merge-source']
for executable in args.git or []:
    command += ['--git', str(executable.absolute())]
subprocess.run(command, cwd=root, check=True)
