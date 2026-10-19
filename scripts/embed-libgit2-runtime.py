#!/usr/bin/env python3
"""Embed the validated libgit2 transport and sign its owned helper."""
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
from runtime_bundle_layout import remove_entry
ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('runtime', type=pathlib.Path)
parser.add_argument('app', type=pathlib.Path)
args = parser.parse_args()
if args.app.suffix != '.app' or not (args.app / 'Contents').is_dir(): parser.error('Expected an application bundle')
validator = ROOT / 'scripts/validate-libgit2-runtime.py'
subprocess.run(['/usr/bin/python3', validator, args.runtime, '--structure-only'], check=True)
target = args.app / 'Contents/Helpers/LibGit2'
remove_entry(target)
target.parent.mkdir(parents=True, exist_ok=True)
shutil.copytree(args.runtime, target)
if os.environ.get('CODE_SIGNING_ALLOWED') == 'YES':
    identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY')
    if not identity: raise RuntimeError('Signing identity unavailable for LibGit2')
    command = ['codesign', '--force', '--sign', identity, '--options', 'runtime']
    inherited = os.environ.get('CONFIGURATION') == 'AppStore'
    if inherited: command += ['--entitlements', str(ROOT / 'Configuration/GitHelper.entitlements')]
    binary = target / 'bin/turtlegit-libgit2'
    subprocess.run(command + [str(binary)], check=True)
    manifest = json.loads((target / 'provenance.json').read_text())
    manifest['unsigned_binary_sha256'] = manifest['binary_sha256']
    manifest['binary_sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
    manifest['signed'] = True; manifest['sandbox_inherited'] = inherited
    (target / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
subprocess.run(['/usr/bin/python3', validator, target, '--structure-only'], check=True)
print('Embedded validated LibGit2 runtime in ' + str(args.app))
