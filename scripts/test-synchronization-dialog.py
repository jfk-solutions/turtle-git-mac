#!/usr/bin/env python3
"""Headless native Synchronization workflow checks; no displayed prompt or signed UI acceptance."""
from native_receiver import build_receiver
import argparse
import os
from pathlib import Path
import platform
import signal
import subprocess
import tempfile
import time
import sys

def close_receiver(receiver):
    """Stop this owned group and reap its leader before probing descendants."""
    try:
        os.killpg(receiver.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        receiver.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(receiver.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        receiver.wait()
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            os.killpg(receiver.pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.05)
    try:
        os.killpg(receiver.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
selection = parser.add_mutually_exclusive_group()
selection.add_argument('--push-only', action='store_true', help='Run the native Push fixture only.')
selection.add_argument('--email-only', action='store_true', help='Run the native Email Patch fixture only.')
selection.add_argument('--apply-only', action='store_true', help='Run the native Apply Patch fixture only.')
selection.add_argument('--branches-only', action='store_true', help='Run the native local/remote branch picker fixture only.')
selection.add_argument('--manage-only', action='store_true', help='Run the native Manage Remote settings fixture only.')
selection.add_argument('--stash-only', action='store_true', help='Run the native Stash fixture only.')
selection.add_argument('--submodules-only', action='store_true', help='Run the native Submodule fixture only.')
selection.add_argument('--tags-only', action='store_true', help='Run the native Compare Tags fixture only.')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
command=[sys.executable,str(root/'scripts/test-sync-owned-form-family.py'),'--only','dialog']
for git in args.git or [Path('/usr/bin/git')]:command += ['--git',str(git)]
environment=os.environ.copy()
for field,key in [('tags_only','TURTLEGIT_SYNC_TAGS_ONLY'),('push_only','TURTLEGIT_SYNC_PUSH_ONLY'),('submodules_only','TURTLEGIT_SYNC_SUBMODULES_ONLY'),('email_only','TURTLEGIT_SYNC_EMAIL_ONLY'),('apply_only','TURTLEGIT_SYNC_APPLY_ONLY'),('branches_only','TURTLEGIT_SYNC_BRANCHES_ONLY'),('manage_only','TURTLEGIT_SYNC_MANAGE_ONLY'),('stash_only','TURTLEGIT_SYNC_STASH_ONLY')]:
    environment.pop(key,None)
    if getattr(args,field):environment[key]='1'
subprocess.run(command,cwd=root,env=environment,check=True)
