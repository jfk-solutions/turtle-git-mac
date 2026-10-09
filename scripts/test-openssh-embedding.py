#!/usr/bin/env python3
"""Exercise unsigned/ad-hoc helper packaging and rollback without launching the app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--runtime',type=Path,default=ROOT/'build/openssh-runtime/OpenSSH')
args = parser.parse_args()
source = args.runtime.resolve()
original = json.loads((source/'provenance.json').read_text())
assert not original['signed']
results = []
with tempfile.TemporaryDirectory(prefix='tg-openssh-embed-') as temporary:
    root = Path(temporary); app = root/'Fixture.app'; (app/'Contents').mkdir(parents=True)
    target = app/'Contents/Helpers/OpenSSH'; manifest = target/'provenance.json'
    def embed(configuration,identity,allowed='YES',runtime=source,expected=0):
        env = os.environ.copy(); env.update({'CODE_SIGNING_ALLOWED':allowed,'CONFIGURATION':configuration})
        env.pop('EXPANDED_CODE_SIGN_IDENTITY',None)
        if identity is not None: env['EXPANDED_CODE_SIGN_IDENTITY'] = identity
        result = subprocess.run(['/usr/bin/python3',ROOT/'scripts/embed-openssh-runtime.py',runtime,app],env=env,capture_output=True,text=True,timeout=60)
        assert (result.returncode == 0) == (expected == 0), (configuration,result.returncode,result.stderr)
        assert not list(target.parent.glob('.openssh-*')), 'Left staged or backup helper directory'
        return result
    embed('Debug',None,allowed='NO')
    assert json.loads(manifest.read_text()) == original
    results.append('unsigned fixture packaging and runtime audit')
    for configuration,inherited in [('Debug',False),('AppStore',True)]:
        embed(configuration,'-')
        value = json.loads(manifest.read_text())
        assert value['signed'] and value['sandbox_inherited'] == inherited
        assert value['unsigned_binary_sha256'] == original['binary_sha256']
        for name in original['pin']['binaries']:
            digest = hashlib.sha256((target/'bin'/name).read_bytes()).hexdigest()
            assert value['binary_sha256'][name] == value['files_sha256']['bin/'+name] == digest
        results.append(configuration+' ad-hoc signatures and post-sign hash audit')
    def snapshot():
        return {str(p.relative_to(target)):hashlib.sha256(p.read_bytes()).hexdigest() for p in target.rglob('*') if p.is_file()}
    before = manifest.read_bytes(); previous_files = snapshot()
    result = embed('AppStore',None,expected=1)
    assert 'signing identity is unavailable' in result.stderr
    assert manifest.read_bytes() == before and snapshot() == previous_files
    results.append('missing identity preserves previous package')
    result = embed('Debug','TurtleGit deliberately missing QA identity',expected=1)
    assert manifest.read_bytes() == before and snapshot() == previous_files
    results.append('failed signing preserves previous package')
    damaged = root/'Damaged'; shutil.copytree(source,damaged)
    with (damaged/'Licenses/OpenSSH-LICENCE.txt').open('ab') as stream: stream.write(b'altered')
    embed('Debug','-',runtime=damaged,expected=1)
    assert manifest.read_bytes() == before and snapshot() == previous_files
    results.append('damaged input preserves previous package')
assert not Path(temporary).exists()
print(json.dumps({'checks':results,'fixture_removed':True,'signed_parent_execution':'UNVERIFIED','main_app_launched':False},indent=2))
