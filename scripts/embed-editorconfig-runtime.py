#!/usr/bin/env python3
"""Embed and sign the verified parser before Xcode signs the containing app."""
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
    parser.error('Expected an Xcode-built app bundle')
if not args.runtime.is_dir():
    parser.error('Build the pinned parser first: python3 scripts/build-editorconfig-runtime.py')
subprocess.run(['/usr/bin/python3', ROOT / 'scripts/validate-editorconfig-runtime.py', args.runtime], check=True)
target = args.app / 'Contents/Helpers/EditorConfig'
if target.exists():
    shutil.rmtree(target)
target.parent.mkdir(parents=True, exist_ok=True)
shutil.copytree(args.runtime, target)
if os.environ.get('CODE_SIGNING_ALLOWED') == 'YES':
    identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY')
    if not identity:
        raise RuntimeError('Xcode signing identity is unavailable for EditorConfig')
    binary = target / 'editorconfig'
    sandbox_inherited = os.environ.get('CONFIGURATION') == 'AppStore'
    signing = ['codesign', '--force', '--sign', identity, '--options', 'runtime']
    if sandbox_inherited:
        signing += ['--entitlements', ROOT / 'Configuration/GitHelper.entitlements']
    subprocess.run(signing + [binary], check=True)
    manifest = json.loads((target / 'provenance.json').read_text())
    manifest['unsigned_binary_sha256'] = manifest['binary_sha256']
    manifest['binary_sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
    manifest['signed'] = True
    manifest['sandbox_inherited'] = sandbox_inherited
    (target / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
subprocess.run(['/usr/bin/python3', ROOT / 'scripts/validate-editorconfig-runtime.py', target], check=True)
print('Embedded verified EditorConfig parser in ' + str(args.app))
