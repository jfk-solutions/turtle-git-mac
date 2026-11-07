#!/usr/bin/env python3
"""Compatibility entry point for the grouped captured Sync family receiver."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--captures',type=Path)
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
command=[sys.executable,str(root/'scripts/test-sync-owned-form-family.py'),'--only','conflict']
for git in args.git or [Path('/usr/bin/git')]:command += ['--git',str(git)]
if args.captures:command += ['--captures',str(args.captures)]
env=os.environ.copy()
subprocess.run(command,cwd=root,env=env,check=True)
