#!/usr/bin/env python3
"""Validate, embed and sign all SSH helpers before the containing app is signed."""
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
    parser.error('Prepare SSH first: python3 scripts/build-openssh-runtime.py')
validator = ROOT/'scripts/validate-openssh-runtime.py'
subprocess.run(['/usr/bin/python3',validator,args.runtime],check=True)
manifest = json.loads((args.runtime/'provenance.json').read_text())
if manifest.get('signed'):
    raise RuntimeError('Embed from the verified unsigned build, not a previously signed copy')
signing = os.environ.get('CODE_SIGNING_ALLOWED') == 'YES'
identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY')
if signing and not identity:
    raise RuntimeError('Xcode signing identity is unavailable for OpenSSH')
target = args.app/'Contents/Helpers/OpenSSH'
target.parent.mkdir(parents=True,exist_ok=True)
stage = target.parent/('.openssh-stage-'+str(uuid.uuid4()))
backup = target.parent/('.openssh-backup-'+str(uuid.uuid4()))
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
    if target.exists(): target.replace(backup)
    try: stage.replace(target)
    except BaseException:
        if backup.exists(): backup.replace(target)
        raise
    if backup.exists(): shutil.rmtree(backup)
finally:
    if stage.exists(): shutil.rmtree(stage)
print('Embedded verified OpenSSH runtime in '+str(args.app))
