#!/usr/bin/env python3
"""Build pinned OpenSSH clients and private-agent tools with static OpenSSL."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run(args, cwd=None, env=None):
    subprocess.run([str(a) for a in args], cwd=cwd, env=env, check=True)

def extract(archive, destination):
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as stream:
        for entry in stream.getmembers():
            target = destination.joinpath(*Path(entry.name).parts[1:])
            if not target.resolve().is_relative_to(destination.resolve()):
                raise RuntimeError('Archive path escapes source directory')
            if entry.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif entry.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(stream.extractfile(entry).read())
                target.chmod(entry.mode & 0o777)
            else:
                raise RuntimeError('Source archive contains a link or special file: ' + entry.name)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT/'build/openssh-runtime/OpenSSH')
    args = parser.parse_args(); output = args.output.resolve()
    pin = json.loads((ROOT/'Configuration/OpenSSHRuntime.json').read_text())
    if output.exists() and not (output/'provenance.json').is_file():
        raise RuntimeError('Refusing to replace an unrecognized runtime directory')
    cache = ROOT/'build/openssh-runtime/cache'; cache.mkdir(parents=True, exist_ok=True)
    archives = {}
    for name in ['openssl', 'openssh']:
        archive = cache/(name+'.tar.gz'); item = pin[name]
        if not archive.exists():
            archived = ROOT/(name+'.tar.gz')
            if archived.is_file(): shutil.copy2(archived, archive)
            else:
                part = archive.with_suffix('.download')
                try:
                    with urllib.request.urlopen(item['url'], timeout=60) as response, part.open('wb') as stream:
                        shutil.copyfileobj(response, stream)
                    part.replace(archive)
                finally:
                    part.unlink(missing_ok=True)
        if digest(archive) != item['sha256']: raise RuntimeError('Source checksum mismatch: '+name)
        archives[name] = archive
    sdk = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'], text=True).strip()
    # Separate source/build trees whenever pins, options, compiler or SDK change.
    build_inputs = {'pin':pin, 'sdk':sdk,
                    'compiler':subprocess.check_output(['/usr/bin/clang','--version'],text=True)}
    build_key = hashlib.sha256(json.dumps(build_inputs,sort_keys=True).encode()).hexdigest()
    workspace = ROOT/'build/openssh-runtime/work'/build_key; workspace.mkdir(parents=True, exist_ok=True)
    for arch in pin['architectures']:
        directory = workspace/arch; directory.mkdir(exist_ok=True)
        crypto = directory/'openssl'; ssh = directory/'openssh'
        if not (crypto/'Configure').is_file(): extract(archives['openssl'], crypto)
        if not (ssh/'configure').is_file(): extract(archives['openssh'], ssh)
        env = os.environ.copy()
        for key in ['CFLAGS','CPPFLAGS','LDFLAGS','LIBS','CPATH','LIBRARY_PATH','PKG_CONFIG_PATH','OPENSSL_CONF','OPENSSL_MODULES','OPENSSL_ENGINES']:
            env.pop(key, None)
        env['MACOSX_DEPLOYMENT_TARGET'] = pin['deployment_target']; env['SDKROOT'] = sdk; env['CC'] = '/usr/bin/clang'
        target = 'darwin64-arm64-cc' if arch == 'arm64' else 'darwin64-x86_64-cc'
        run(['/usr/bin/perl','Configure',target,*pin['openssl_options'],'--prefix=/turtlegit/openssl','--openssldir=/turtlegit/openssl','-mmacosx-version-min='+pin['deployment_target']], cwd=crypto, env=env)
        run(['/usr/bin/make','-j4','build_libs'], cwd=crypto, env=env)
        prefix = directory/'crypto-prefix'; (prefix/'lib').mkdir(parents=True, exist_ok=True)
        shutil.copytree(crypto/'include', prefix/'include', dirs_exist_ok=True)
        shutil.copy2(crypto/'libcrypto.a', prefix/'lib/libcrypto.a')
        env.update({'CC':'/usr/bin/clang -arch '+arch,
                    'CFLAGS':'-O2 -mmacosx-version-min='+pin['deployment_target'],
                    'LDFLAGS':'-mmacosx-version-min='+pin['deployment_target'],
                    'PKG_CONFIG':'/usr/bin/false'})
        run(['./configure','--host='+arch+'-apple-darwin','--prefix=/turtlegit/openssh','--sysconfdir=/turtlegit/openssh/etc',
             '--with-ssl-dir='+str(prefix),'--without-pam','--without-libedit','--without-kerberos5','--without-security-key-builtin'], cwd=ssh, env=env)
        run(['/usr/bin/make','-j4',*pin['binaries']], cwd=ssh, env=env)
    stage = output.parent/('.openssh-stage-'+str(uuid.uuid4())); stage.mkdir(parents=True)
    try:
        (stage/'bin').mkdir(); (stage/'Licenses').mkdir(); (stage/'Sources/build').mkdir(parents=True); (stage/'Sources/Configuration').mkdir()
        binaries = {}
        for binary in pin['binaries']:
            path = stage/'bin'/binary
            run(['/usr/bin/lipo','-create',*[workspace/a/'openssh'/binary for a in pin['architectures']],'-output',path]); path.chmod(0o755)
            binaries[binary] = digest(path)
        shutil.copy2(workspace/'arm64/openssh/LICENCE',stage/'Licenses/OpenSSH-LICENCE.txt')
        shutil.copy2(workspace/'arm64/openssl/LICENSE.txt',stage/'Licenses/OpenSSL-LICENSE.txt')
        for name, archive in archives.items(): shutil.copy2(archive, stage/'Sources'/(name+'.tar.gz'))
        shutil.copy2(__file__, stage/'Sources/build/build-openssh-runtime.py')
        shutil.copy2(Path(__file__).with_name('validate-openssh-runtime.py'), stage/'Sources/build/validate-openssh-runtime.py')
        shutil.copy2(ROOT/'Configuration/OpenSSHRuntime.json',stage/'Sources/Configuration/OpenSSHRuntime.json')
        manifest = {'pin':pin,'signed':False,'binary_sha256':binaries,
                    'toolchain':subprocess.check_output(['/usr/bin/clang','--version'],text=True).splitlines()[0],
                    'sdk':Path(sdk).name,
                    'reconstruction':'python3 Sources/build/build-openssh-runtime.py --output rebuilt',
                    'files_sha256':{str(p.relative_to(stage)):digest(p) for p in sorted(stage.rglob('*')) if p.is_file()}}
        (stage/'provenance.json').write_text(json.dumps(manifest,indent=2)+'\n')
        run(['/usr/bin/python3', Path(__file__).with_name('validate-openssh-runtime.py'), stage])
        backup = output.parent/('.openssh-backup-'+str(uuid.uuid4()))
        if output.exists(): output.replace(backup)
        try:
            stage.replace(output)
        except BaseException:
            if backup.exists(): backup.replace(output)
            raise
        if backup.exists(): shutil.rmtree(backup)
    finally:
        if stage.exists(): shutil.rmtree(stage)
    print('Built pinned universal OpenSSH runtime: '+str(output))

if __name__ == '__main__': main()
