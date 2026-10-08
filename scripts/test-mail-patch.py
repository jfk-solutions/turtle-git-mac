#!/usr/bin/env python3
"""Run real-Git mail import/recovery Core tests with selected Git engines."""
import argparse
import os
from pathlib import Path
import subprocess
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
    environment = os.environ.copy()
    environment['TURTLEGIT_MAIL_TEST_GIT'] = str(git.resolve())
    print('Checking ' + str(git), flush=True)
    command = ['swift', 'test', '--filter', 'MailPatchTests']
    if index:
        command.append('--skip-build')
    subprocess.run(command, cwd=root, env=environment, check=True)
