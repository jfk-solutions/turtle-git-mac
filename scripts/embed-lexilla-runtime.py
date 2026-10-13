#!/usr/bin/env python3
"""Embed the verified Lexilla helper with inherited App Store sandbox signing."""
from runtime_bundle_layout import remove_entry
import hashlib,json,os,shutil,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
runtime,app=map(Path,sys.argv[1:])
assert app.suffix=='.app' and (app/'Contents').is_dir()
subprocess.run(['/usr/bin/python3',ROOT/'scripts/validate-lexilla-runtime.py',runtime],check=True)
target=app/'Contents/Helpers/Lexilla'
if target.exists() or target.is_symlink():remove_entry(target)
target.parent.mkdir(parents=True,exist_ok=True);shutil.copytree(runtime,target)
if os.environ.get('CODE_SIGNING_ALLOWED')=='YES':
    identity=os.environ.get('EXPANDED_CODE_SIGN_IDENTITY')
    if not identity:raise RuntimeError('Missing Lexilla signing identity')
    arguments=['codesign','--force','--sign',identity,'--options','runtime']
    inherited=os.environ.get('CONFIGURATION')=='AppStore'
    if inherited:arguments+=['--entitlements',str(ROOT/'Configuration/GitHelper.entitlements')]
    subprocess.run(arguments+[str(target/'lexilla')],check=True)
    p=target/'provenance.json';manifest=json.loads(p.read_text())
    manifest['unsigned_binary_sha256']=manifest['files']['lexilla']
    manifest['files']['lexilla']=hashlib.sha256((target/'lexilla').read_bytes()).hexdigest()
    manifest['sandbox_inherited']=inherited;p.write_text(json.dumps(manifest,indent=2)+'\n')
subprocess.run(['/usr/bin/python3',ROOT/'scripts/validate-lexilla-runtime.py',target],check=True)
print('Embedded verified Lexilla helper.')
