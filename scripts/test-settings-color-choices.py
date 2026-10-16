#!/usr/bin/env python3
"""Connected native color-settings controls and retained Merge Colors workflow."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--capture-dir',type=Path)
args=parser.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-settings-colors-') as temporary:
    receiver=build_receiver(root,[root/'docs/qa/settings-color-choices-native-2026-10-16.swift',root/'docs/qa/merge-colors-native-2026-10-12.swift'],Path(temporary))
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    if args.capture_dir:env['TURTLEGIT_SETTINGS_COLOR_CAPTURES']=str(args.capture_dir.resolve())
    result=run_receiver([str(receiver)],cwd=root,env=env,capture_output=True,text=True)
    print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
    if 'PASS: connected Settings color controls' not in result.stdout:raise SystemExit('Native receiver exited before final assertion')
