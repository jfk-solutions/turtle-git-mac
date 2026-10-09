#!/usr/bin/env python3
"""Audit universal SSH helpers and exercise a private fixture agent, never login SSH."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('runtime', type=Path)
args = parser.parse_args(); runtime = args.runtime.resolve()
pin = json.loads((ROOT/'Configuration/OpenSSHRuntime.json').read_text())
manifest = json.loads((runtime/'provenance.json').read_text())
assert manifest['pin'] == pin
assert set(manifest['binary_sha256']) == set(pin['binaries'])
for relative, expected in manifest['files_sha256'].items():
    path = runtime/relative
    assert path.resolve().is_relative_to(runtime) and not path.is_symlink(), relative
    assert hashlib.sha256(path.read_bytes()).hexdigest() == expected, relative
expected_files = {'bin/'+name for name in pin['binaries']} | {
    'Licenses/OpenSSH-LICENCE.txt', 'Licenses/OpenSSL-LICENSE.txt',
    'Sources/openssh.tar.gz', 'Sources/openssl.tar.gz',
    'Sources/build/build-openssh-runtime.py', 'Sources/build/validate-openssh-runtime.py',
    'Sources/Configuration/OpenSSHRuntime.json'}
assert set(manifest['files_sha256']) == expected_files, 'Unexpected manifest inventory'
assert not any(p.is_symlink() for p in runtime.rglob('*')), 'Runtime contains symlinks'
assert expected_files | {'provenance.json'} == {str(p.relative_to(runtime)) for p in runtime.rglob('*') if p.is_file()}, 'Unexpected runtime inventory'
for name in ['openssh','openssl']:
    assert hashlib.sha256((runtime/'Sources'/(name+'.tar.gz')).read_bytes()).hexdigest() == pin[name]['sha256']
assert json.loads((runtime/'Sources/Configuration/OpenSSHRuntime.json').read_text()) == pin
for name in pin['binaries']:
    path = runtime/'bin'/name
    assert os.access(path,os.X_OK) and hashlib.sha256(path.read_bytes()).hexdigest() == manifest['binary_sha256'][name]
    assert set(subprocess.check_output(['/usr/bin/lipo','-archs',path],text=True).split()) == set(pin['architectures'])
    versions = subprocess.check_output(['xcrun','vtool','-show-build',path],text=True)
    assert re.findall(r'\bminos\s+([0-9.]+)',versions) == [pin['deployment_target']]*len(pin['architectures']), name
    for line in subprocess.check_output(['/usr/bin/otool','-L',path],text=True).splitlines():
        if line.startswith('\t'):
            assert line.strip().split(' (')[0].startswith(('/usr/lib/','/System/Library/')), line
for name in ['OpenSSH-LICENCE.txt','OpenSSL-LICENSE.txt']:
    assert (runtime/'Licenses'/name).stat().st_size > 1000
assert not manifest.get('signed'), 'Use native signed-parent acceptance for inherited sandbox helpers'
with tempfile.TemporaryDirectory(prefix='tg-openssh-audit-') as temporary:
    root = Path(temporary); socket = root/'s'
    assert len(str(socket).encode()) < 104
    env = {'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(root),'TMPDIR':str(root),'LANG':'C','SSH_ASKPASS_REQUIRE':'never'}
    def run(name,*arguments,codes=(0,)):
        result = subprocess.run([runtime/'bin'/name,*arguments],env=env,capture_output=True,text=True,timeout=15)
        assert result.returncode in codes,(name,result.returncode,result.stderr)
        return result
    version = run('ssh','-V').stderr
    assert 'OpenSSH_'+pin['openssh']['version'] in version and 'OpenSSL '+pin['openssl']['version'] in version,version
    config = run('ssh','-F','/dev/null','-G','fixture.invalid').stdout
    assert 'hostname fixture.invalid' in config
    with (root/'agent.log').open('w') as log:
        agent = subprocess.Popen([runtime/'bin/ssh-agent','-D','-a',socket],env=env,stdout=log,stderr=log,start_new_session=True)
        try:
            end = time.monotonic()+10
            while not socket.exists() and agent.poll() is None and time.monotonic()<end: time.sleep(.02)
            assert socket.exists() and agent.poll() is None,'Private agent startup'
            env['SSH_AUTH_SOCK'] = str(socket)
            fingerprints = []
            for kind in ['ed25519','ecdsa','rsa']:
                key = root/kind
                arguments = ['-q','-t',kind,'-N','','-C','TurtleGit-'+kind,'-f',str(key)]
                if kind == 'rsa': arguments += ['-b','2048']
                run('ssh-keygen',*arguments); run('ssh-add',str(key))
                fingerprints.append(run('ssh-keygen','-l','-f',str(key)+'.pub').stdout.split()[1])
            listed = run('ssh-add','-l').stdout
            assert all(f in listed for f in fingerprints)
            run('ssh-add','-D'); assert run('ssh-add','-l',codes=(1,)).returncode == 1
            encrypted = root/'encrypted'
            run('ssh-keygen','-q','-t','ed25519','-N','private fixture phrase','-C','encrypted','-f',str(encrypted))
            assert run('ssh-add',str(encrypted),codes=(1,)).returncode == 1
        finally:
            if agent.poll() is None: agent.terminate()
            try: agent.wait(timeout=5)
            except subprocess.TimeoutExpired:
                agent.kill(); agent.wait(timeout=5)
            assert agent.poll() is not None
print('OpenSSH '+pin['openssh']['version']+' / OpenSSL '+pin['openssl']['version']+': universal macOS '+pin['deployment_target']+', system-only linkage, archives/licenses/reconstruction hashes and private '+platform.machine()+' agent Ed25519/ECDSA/RSA loading/removal/encrypted refusal passed. No network, login-agent or signed acceptance.')
