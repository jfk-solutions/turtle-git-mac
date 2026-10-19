#!/usr/bin/env python3
"""Build the pinned static libgit2 transport and macOS-only universal helper."""
import argparse, hashlib, json, os, pathlib, shutil, subprocess, tarfile, tempfile, uuid
from pinned_download import download_verified
ROOT=pathlib.Path(__file__).resolve().parents[1]
FILES=['LICENSE','NOTICE','Configuration/LibGit2Runtime.json','Sources/TurtleGitLibgit2/main.swift','Sources/TurtleGitLibgit2/HTTPConfiguration.swift','Sources/TurtleGitLibgit2/bridge.c','Sources/TurtleGitLibgit2/bridge.h','Sources/TurtleGitLibgit2/module.modulemap','Sources/TurtleGitCore/GitAskpassPrompt.swift','Sources/TurtleGitCore/GitSVNAuthenticationPrompt.swift','Sources/TurtleGitCore/GitRemoteAuthenticationPrompt.swift','patches/libgit2-authority.patch','scripts/build-libgit2-runtime.py','scripts/embed-libgit2-runtime.py','scripts/validate-libgit2-runtime.py','scripts/pinned_download.py','scripts/runtime_bundle_layout.py','scripts/git_lfs_runtime.py']
CMAKE=['-DCMAKE_BUILD_TYPE=Release','-DBUILD_SHARED_LIBS=OFF','-DBUILD_TESTS=OFF','-DBUILD_CLI=OFF','-DBUILD_EXAMPLES=OFF','-DUSE_HTTPS=SecureTransport','-DUSE_SSH=exec','-DUSE_SHA1=CollisionDetection','-DUSE_SHA256=CommonCrypto','-DUSE_HTTP_PARSER=builtin','-DREGEX_BACKEND=builtin','-DUSE_BUNDLED_ZLIB=OFF','-DUSE_GSSAPI=OFF','-DUSE_NTLMCLIENT=ON','-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local','-DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=TRUE','-DCMAKE_DISABLE_FIND_PACKAGE_mbedTLS=TRUE','-DCMAKE_DISABLE_FIND_PACKAGE_PCRE=TRUE']
SWIFT_FLAGS=['-O','-whole-module-optimization','-framework','Security','-framework','CoreFoundation','-lz','-liconv','-lresolv']
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def run(args,**kwargs):subprocess.run([str(v) for v in args],check=True,**kwargs)
def extract(archive,destination):
    with tarfile.open(archive) as stream:
        for member in stream:
            relative=pathlib.PurePosixPath(*pathlib.PurePosixPath(member.name).parts[1:]);target=destination/relative
            if not target.resolve().is_relative_to(destination.resolve()):raise RuntimeError('Escaping source archive')
            if member.isdir():target.mkdir(parents=True,exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(stream.extractfile(member).read());target.chmod(member.mode & 0o777)
            elif member.issym():
                link=pathlib.Path(member.linkname)
                if link.is_absolute() or not (target.parent/link).resolve().is_relative_to(destination.resolve()):raise RuntimeError('Escaping source symlink')
                target.parent.mkdir(parents=True,exist_ok=True);target.symlink_to(member.linkname)
            else:raise RuntimeError('Unsupported source archive entry: '+member.name)
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=pathlib.Path,default=ROOT/'build/libgit2-runtime/LibGit2');args=parser.parse_args();output=args.output.resolve()
    if output.exists() and not (output/'provenance.json').is_file():raise RuntimeError('Refusing unrecognized runtime output')
    pin=json.loads((ROOT/'Configuration/LibGit2Runtime.json').read_text());cache=ROOT/'build/libgit2-runtime/cache';cache.mkdir(parents=True,exist_ok=True)
    archive=cache/('libgit2-'+pin['libgit2']['commit']+'.tar.gz')
    bundled=ROOT.parent/'libgit2.tar.gz'
    if not archive.exists() and bundled.is_file():shutil.copy2(bundled,archive)
    download_verified(pin['libgit2']['url'],archive,pin['libgit2']['sha256'])
    compiler=subprocess.check_output(['xcrun','swiftc','--version'],text=True);clang=subprocess.check_output(['xcrun','clang','--version'],text=True);cmake=subprocess.check_output(['cmake','--version'],text=True)
    sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip();sdk_version=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-version'],text=True).strip()
    hashes={name:digest(ROOT/name) for name in FILES}
    key=hashlib.sha256(json.dumps([pin,hashes,compiler,clang,cmake,sdk_version,CMAKE,SWIFT_FLAGS],sort_keys=True).encode()).hexdigest();work=cache/key;work.mkdir(exist_ok=True);binary=work/'turtlegit-libgit2';source=work/'source'
    if not binary.is_file():
        if source.exists():shutil.rmtree(source)
        source.mkdir();extract(archive,source)
        run(['/usr/bin/patch','-f','-F','0','-p1','-i',ROOT/pin['patch']],cwd=source)
        slices=[]
        for arch in pin['architectures']:
            build=work/arch
            run(['cmake','-S',source,'-B',build,*CMAKE,'-DCMAKE_OSX_ARCHITECTURES='+arch,'-DCMAKE_OSX_DEPLOYMENT_TARGET='+pin['deployment_target'],'-DCMAKE_OSX_SYSROOT='+sdk,'-DZLIB_INCLUDE_DIR='+sdk+'/usr/include','-DZLIB_LIBRARY='+sdk+'/usr/lib/libz.tbd','-DICONV_INCLUDE_DIR='+sdk+'/usr/include','-Diconv_lib='+sdk+'/usr/lib/libiconv.tbd'])
            run(['cmake','--build',build,'--target','libgit2package','--parallel','4'])
            libraries=list(build.glob('**/libgit2.a'))
            if len(libraries)!=1:raise RuntimeError('Expected one pinned static libgit2 archive')
            bridge=build/'turtlegit-bridge.o'
            run(['xcrun','clang','-O2','-arch',arch,'-isysroot',sdk,'-mmacosx-version-min='+pin['deployment_target'],'-I',source/'include','-c',ROOT/'Sources/TurtleGitLibgit2/bridge.c','-o',bridge])
            part=work/('turtlegit-libgit2-'+arch)
            run(['xcrun','swiftc',*SWIFT_FLAGS,'-sdk',sdk,'-target',arch+'-apple-macosx'+pin['deployment_target'],'-I',ROOT/'Sources/TurtleGitLibgit2',ROOT/'Sources/TurtleGitLibgit2/main.swift',ROOT/'Sources/TurtleGitLibgit2/HTTPConfiguration.swift',ROOT/'Sources/TurtleGitCore/GitAskpassPrompt.swift',ROOT/'Sources/TurtleGitCore/GitSVNAuthenticationPrompt.swift',ROOT/'Sources/TurtleGitCore/GitRemoteAuthenticationPrompt.swift',bridge,libraries[0],'-o',part]);slices.append(part)
        run(['lipo','-create',*slices,'-output',binary])
    stage=output.with_name(output.name+'-stage-'+uuid.uuid4().hex);stage.mkdir(parents=True)
    try:
        (stage/'bin').mkdir();shutil.copy2(binary,stage/'bin/turtlegit-libgit2')
        (stage/'Licenses').mkdir();licenses={'LICENSE':ROOT/'LICENSE','NOTICE':ROOT/'NOTICE','Licenses/libgit2-COPYING.txt':source/'COPYING','Licenses/libgit2-AUTHORS.txt':source/'AUTHORS','Licenses/llhttp-MIT.txt':source/'deps/llhttp/LICENSE-MIT','Licenses/PCRE-COPYING.txt':source/'deps/pcre/COPYING'}
        for name,path in licenses.items():shutil.copy2(path,stage/name)
        sources=stage/'Sources/build';sources.mkdir(parents=True);shutil.copy2(archive,stage/'Sources/libgit2.tar.gz')
        for name in FILES:
            target=sources/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/name,target)
        manifest={'pins':pin,'binary_sha256':digest(stage/'bin/turtlegit-libgit2'),'source_sha256':hashes,'license_sha256':{name:digest(stage/name) for name in licenses},'compiler':compiler,'clang':clang,'cmake':cmake,'sdk_version':sdk_version,'cmake_flags':CMAKE,'swift_flags':SWIFT_FLAGS,'cache_key':key,'signed':False}
        (stage/'provenance.json').write_text(json.dumps(manifest,indent=2)+'\n')
        run(['python3',ROOT/'scripts/validate-libgit2-runtime.py',stage,'--structure-only'])
        if output.exists():shutil.rmtree(output)
        stage.rename(output)
    finally:
        if stage.exists():shutil.rmtree(stage)
    print('Built pinned universal LibGit2 runtime: '+str(output))
if __name__=='__main__':main()
