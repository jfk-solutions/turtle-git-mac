#!/usr/bin/env python3
"""Embed the merge adapter; its dynamic libraries are shared with bundled GitSVN."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('runtime', type=Path); parser.add_argument('app', type=Path)
args = parser.parse_args()
assert args.app.suffix == '.app' and (args.app / 'Contents').is_dir()
if not args.runtime.is_dir():
    if os.environ.get('CONFIGURATION') == 'AppStore': raise RuntimeError('Prepare the merge engine before an App Store build.')
    print('MergeDiff not prepared for this development build.'); raise SystemExit(0)
subprocess.run(['python3', str(root / 'scripts/validate-merge-diff-runtime.py'), str(args.runtime)], check=True)
target = args.app / 'Contents/Helpers/MergeDiff'
if target.exists(): shutil.rmtree(target)
target.parent.mkdir(parents=True, exist_ok=True); shutil.copytree(args.runtime, target)
if os.environ.get('CODE_SIGNING_ALLOWED') == 'YES':
    identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY'); assert identity, 'Missing Xcode signing identity.'
    binary = target / 'merge-diff'; inherited = os.environ.get('CONFIGURATION') == 'AppStore'
    signing = ['codesign', '--force', '--sign', identity, '--options', 'runtime']
    if inherited: signing += ['--entitlements', str(root / 'Configuration/GitHelper.entitlements')]
    subprocess.run(signing + [str(binary)], check=True)
    manifest = json.loads((target / 'provenance.json').read_text())
    manifest['unsigned_binary_sha256'] = manifest['binary_sha256']
    manifest['binary_sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
    manifest['signed'] = True; manifest['sandbox_inherited'] = inherited
    (target / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
subprocess.run(['python3', str(root / 'scripts/validate-merge-diff-runtime.py'), str(target)], check=True)
print('Embedded Subversion merge adapter; shared GitSVN libraries retain their own source/license audit.')
