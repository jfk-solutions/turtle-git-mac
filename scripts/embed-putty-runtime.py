#!/usr/bin/env python3
"""Validate, embed and sign the key conversion helper before the containing app is signed."""
from runtime_bundle_layout import remove_entry
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('runtime',type=Path)
parser.add_argument('app',type=Path)
args = parser.parse_args()
if args.app.suffix != '.app' or not (args.app/'Contents').is_dir():
    parser.error('Expected an Xcode-built app bundle')
if not args.runtime.is_dir():
    parser.error('Prepare PuTTY first: python3 scripts/build-putty-runtime.py')
validator = ROOT/'scripts/validate-putty-runtime.py'
subprocess.run(['/usr/bin/python3',validator,args.runtime],check=True)
manifest = json.loads((args.runtime/'provenance.json').read_text())
if manifest.get('signed'):
    raise RuntimeError('Embed from the verified unsigned build, not a previously signed copy')
signing = os.environ.get('CODE_SIGNING_ALLOWED') == 'YES'
identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY')
if signing and not identity:
    raise RuntimeError('Xcode signing identity is unavailable for PuTTY')
target = args.app/'Contents/Helpers/PuTTY'
target.parent.mkdir(parents=True,exist_ok=True)
stage = target.parent/('.putty-stage-'+str(uuid.uuid4()))
backup = target.parent/('.putty-backup-'+str(uuid.uuid4()))
try:
    shutil.copytree(args.runtime,stage)
    if signing:
        manifest['unsigned_binary_sha256'] = manifest['binary_sha256'].copy()
        inherited = os.environ.get('CONFIGURATION') == 'AppStore'
        for name in manifest['pin']['binaries']:
            binary = stage/'bin'/name
            command = ['/usr/bin/codesign','--force','--sign',identity,'--options','runtime']
            if inherited: command += ['--entitlements',ROOT/'Configuration/GitHelper.entitlements']
            subprocess.run(command+[binary],check=True)
            digest = hashlib.sha256(binary.read_bytes()).hexdigest()
            manifest['binary_sha256'][name] = digest
            manifest['files_sha256']['bin/'+name] = digest
        manifest['signed'] = True
        manifest['sandbox_inherited'] = inherited
        (stage/'provenance.json').write_text(json.dumps(manifest,indent=2)+'\n')
    subprocess.run(['/usr/bin/python3',validator,stage],check=True)
    if target.exists() or target.is_symlink(): target.replace(backup)
    try: stage.replace(target)
    except BaseException:
        if backup.exists(): backup.replace(target)
        raise
    if backup.exists() or backup.is_symlink(): remove_entry(backup)
finally:
    if stage.exists(): shutil.rmtree(stage)
print('Embedded verified PuTTY runtime in '+str(args.app))
