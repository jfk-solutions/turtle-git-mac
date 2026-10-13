#!/usr/bin/env python3
"""Build the pinned PuTTY key conversion CLI, licenses and reconstruction sources."""
import argparse, hashlib, json, os, re, shutil, subprocess, tarfile, uuid
from pathlib import Path
from pinned_download import download_verified
ROOT=Path(__file__).resolve().parents[1]
def run(args): subprocess.run(list(map(str,args)),check=True)
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=ROOT/'build/putty-runtime/PuTTY')
    args=parser.parse_args();output=args.output.resolve()
    if output.exists() and not (output/'provenance.json').is_file(): raise RuntimeError('Refusing to replace an unowned directory')
    pin=json.loads((ROOT/'Configuration/PuTTYRuntime.json').read_text())
    cache=ROOT/'build/putty-runtime/cache';cache.mkdir(parents=True,exist_ok=True)
    archive=cache/('putty-'+pin['putty']['version']+'.tar.gz')
    bundled=ROOT.parent/'putty.tar.gz' if ROOT.name=='build' and ROOT.parent.name=='Sources' else None
    if not archive.exists() and bundled is not None and bundled.is_file(): shutil.copy2(bundled,archive)
    download_verified(pin['putty']['url'],archive,pin['putty']['sha256'])
    source=ROOT/'build/putty-runtime/source';source.mkdir(parents=True,exist_ok=True)
    with tarfile.open(archive) as inputs:
        for member in inputs.getmembers():
            relative=Path(*Path(member.name).parts[1:]);target=source/relative
            if not target.resolve().is_relative_to(source.resolve()): raise RuntimeError('Source archive path escapes its root')
            if member.isdir(): target.mkdir(parents=True,exist_ok=True)
            elif member.isfile(): target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(inputs.extractfile(member).read())
            else: raise RuntimeError('Source archive contains a link or special file')
    binaries=[]
    for arch in pin['architectures']:
        directory=ROOT/'build/putty-runtime/work'/arch
        flags='-march=x86-64 -mtune=generic' if arch=='x86_64' else '-march=armv8-a'
        run(['cmake','-S',source,'-B',directory,'-DCMAKE_BUILD_TYPE=Release','-DPUTTY_GTK_VERSION=NONE',
             '-DCMAKE_OSX_ARCHITECTURES='+arch,'-DCMAKE_OSX_DEPLOYMENT_TARGET='+pin['deployment_target'],
             '-DCMAKE_C_FLAGS='+flags])
        run(['cmake','--build',directory,'--target','puttygen','--parallel',str(min(8,os.cpu_count() or 4))])
        binaries.append(directory/'puttygen')
    stage=output.with_name(output.name+'.prepared-'+uuid.uuid4().hex);stage.mkdir(parents=True)
    try:
        (stage/'bin').mkdir();binary=stage/'bin/puttygen'
        run(['lipo','-create',*binaries,'-output',binary]);binary.chmod(0o755)
        archs=subprocess.check_output(['lipo','-archs',binary],text=True).split()
        versions=subprocess.check_output(['xcrun','vtool','-show-build',binary],text=True)
        linkage=subprocess.check_output(['otool','-L',binary],text=True)
        if set(archs)!=set(pin['architectures']) or set(re.findall(r'\bminos\s+([0-9.]+)',versions))!={pin['deployment_target']}: raise RuntimeError('PuTTY architecture/deployment mismatch')
        (stage/'Licenses').mkdir();shutil.copy2(source/'LICENCE',stage/'Licenses/PuTTY-LICENCE.txt')
        reconstruction=stage/'Sources/build';(reconstruction/'Configuration').mkdir(parents=True);(reconstruction/'scripts').mkdir()
        shutil.copy2(archive,stage/'Sources/putty.tar.gz')
        shutil.copy2(ROOT/'Configuration/PuTTYRuntime.json',reconstruction/'Configuration/PuTTYRuntime.json')
        for name in ['build-putty-runtime.py','pinned_download.py']: shutil.copy2(ROOT/'scripts'/name,reconstruction/'scripts'/name)
        (stage/'Sources/README.txt').write_text('Unmodified PuTTY source, licence and reconstruction scripts.\nRun python3 build/scripts/build-putty-runtime.py with macOS SDK, CMake and Python 3.9+.\nOnly the puttygen CLI is built; native UI belongs to TurtleGit.\n')
        files={str(p.relative_to(stage)):hashlib.sha256(p.read_bytes()).hexdigest() for p in stage.rglob('*') if p.is_file()}
        (stage/'provenance.json').write_text(json.dumps({'pin':pin,'binary_sha256':{'puttygen':files['bin/puttygen']},'files_sha256':files,'architectures':archs,'build_versions':versions,'system_linkage':linkage,'signed':False},indent=2)+'\n')
        if output.exists(): shutil.rmtree(output)
        stage.rename(output)
    finally:
        if stage.exists(): shutil.rmtree(stage)
    print(output)
if __name__=='__main__': main()
