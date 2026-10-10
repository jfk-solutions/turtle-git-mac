#!/usr/bin/env python3
"""Embed the validated layout adapter; sign it before the containing application."""
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('runtime', type=pathlib.Path)
parser.add_argument('app', type=pathlib.Path)
args = parser.parse_args()
if args.app.suffix != '.app' or not (args.app / 'Contents').is_dir():
    parser.error('Expected an Xcode-built application bundle')
validator = ROOT / 'scripts/validate-graph-layout-runtime.py'
subprocess.run(['/usr/bin/python3', validator, args.runtime], check=True)
target = args.app / 'Contents/Helpers/GraphLayout'
if target.exists():
    shutil.rmtree(target)
target.parent.mkdir(parents=True, exist_ok=True)
shutil.copytree(args.runtime, target)
if os.environ.get('CODE_SIGNING_ALLOWED') == 'YES':
    identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY')
    if not identity:
        raise RuntimeError('Xcode signing identity unavailable for GraphLayout')
    command = ['codesign', '--force', '--sign', identity, '--options', 'runtime']
    inherited = os.environ.get('CONFIGURATION') == 'AppStore'
    if inherited:
        command += ['--entitlements', ROOT / 'Configuration/GitHelper.entitlements']
    binary = target / 'graph-layout'
    subprocess.run(command + [binary], check=True)
    manifest = json.loads((target / 'provenance.json').read_text())
    manifest['unsigned_binary_sha256'] = manifest['binary_sha256']
    manifest['binary_sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
    manifest['signed'] = True; manifest['sandbox_inherited'] = inherited
    (target / 'provenance.json').write_text(json.dumps(manifest, indent=2)+'\n')
subprocess.run(['/usr/bin/python3', validator, target], check=True)
print('Embedded validated GraphLayout in '+str(args.app))
