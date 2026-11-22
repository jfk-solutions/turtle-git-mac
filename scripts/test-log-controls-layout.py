#!/usr/bin/env python3
"""Native source Log controls, split layout and stable feedback/footer family."""
import argparse
from pathlib import Path
import subprocess
import sys
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--captures',type=Path)
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
command=[sys.executable,str(root/'scripts/test-history-feedback-conflict-batch.py'),'--only','legacy-log','--only','log']
for git in args.git or [Path('/usr/bin/git')]:command += ['--git',str(git)]
if args.captures:command += ['--captures',str(args.captures)]
subprocess.run(command,cwd=root,check=True)
