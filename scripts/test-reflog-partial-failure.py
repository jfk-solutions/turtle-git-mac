#!/usr/bin/env python3
"""Compatibility entry for the private connected RefLog partial-failure case."""
import argparse
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
command = [sys.executable, str(root / 'scripts/test-reflog-lifecycle.py'), '--only', 'partial']
for git in args.git or [Path('/usr/bin/git')]:
    command.extend(['--git', str(git)])
subprocess.run(command, cwd=root, check=True)
