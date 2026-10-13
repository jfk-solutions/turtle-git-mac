#!/usr/bin/env python3
"""Embed the prepared Git runtime before Xcode signs the containing app."""
from runtime_bundle_layout import remove_entry
import argparse
import json
import os
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
MACH = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('runtime', type=pathlib.Path)
parser.add_argument('app', type=pathlib.Path)
args = parser.parse_args()
if args.app.suffix != '.app' or not (args.app / 'Contents').is_dir(): parser.error('Expected an Xcode-built .app bundle.')
if not args.runtime.is_dir(): parser.error('Build the pinned runtime first: python3 scripts/build-git-runtime.py')
pin = json.loads((ROOT / 'Configuration/GitRuntime.json').read_text())
manifest = json.loads((args.runtime / 'runtime-manifest.json').read_text())
assert manifest['version'] == pin['version'] and manifest['source_sha256'] == pin['source_sha256'], 'Runtime does not match pinned source.'
subprocess.run(['/usr/bin/python3', str(ROOT / 'scripts/validate-git-runtime.py'), str(args.runtime), '--require-lfs', '--require-svn'], check=True)
target = args.app / 'Contents/Helpers/Git'
if target.exists() or target.is_symlink(): remove_entry(target)
target.parent.mkdir(parents=True, exist_ok=True)
shutil.copytree(args.runtime, target, symlinks=True)
print('Embedded pinned Git runtime in ' + str(args.app))
