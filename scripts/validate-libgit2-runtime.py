#!/usr/bin/env python3
"""Audit the pinned universal libgit2 helper, reconstruction and SDK-only linkage."""
import argparse,hashlib,json,os,pathlib,plistlib,re,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('runtime',type=pathlib.Path);parser.add_argument('--structure-only',action='store_true');parser.add_argument('--all-architectures',action='store_true');args=parser.parse_args();runtime=args.runtime.resolve()
    manifest=json.loads((runtime/'provenance.json').read_text());pin=json.loads((ROOT/'Configuration/LibGit2Runtime.json').read_text());assert manifest['pins']==pin
    binary=runtime/'bin/turtlegit-libgit2';assert digest(binary)==manifest['binary_sha256'];assert os.access(binary,os.X_OK)
    assert digest(runtime/'Sources/libgit2.tar.gz')==pin['libgit2']['sha256'];assert digest(ROOT/pin['patch'])==pin['patch_sha256']
    for relative,expected in manifest['source_sha256'].items():
        assert digest(ROOT/relative)==expected,relative;assert digest(runtime/'Sources/build'/relative)==expected,relative
    for relative,expected in manifest['license_sha256'].items():assert digest(runtime/relative)==expected,relative
    assert 'LINKING EXCEPTION' in (runtime/'Licenses/libgit2-COPYING.txt').read_text()
    archs=subprocess.check_output(['lipo','-archs',binary],text=True).split();assert set(archs)==set(pin['architectures'])
    for arch in archs:
        versions=subprocess.check_output(['xcrun','vtool','-arch',arch,'-show-build',binary],text=True);assert re.findall(r'\bminos\s+([0-9.]+)',versions)==[pin['deployment_target']]
        links=subprocess.check_output(['otool','-arch',arch,'-L',binary],text=True)
        for line in links.splitlines()[1:]:assert line.strip().split(' ',1)[0].startswith(('/usr/lib/','/System/Library/')),line
    if manifest.get('signed'):
        subprocess.run(['codesign','--verify','--strict',binary],check=True);assert re.fullmatch('[0-9a-f]{64}',manifest['unsigned_binary_sha256'])
        if manifest.get('sandbox_inherited'):
            result=subprocess.run(['codesign','-d','--entitlements',':-',binary],capture_output=True,check=True);entitlements=plistlib.loads(result.stdout);assert entitlements.get('com.apple.security.app-sandbox') and entitlements.get('com.apple.security.inherit')
            print('LibGit2: pinned sources, universal slices, SDK linkage and inherited signature verified; signed parent execution separate.');return
    else:assert not manifest.get('sandbox_inherited')
    if not args.structure_only:
        prefixes=[['arch','-'+arch] for arch in pin['architectures']] if args.all_architectures else [[]]
        for prefix in prefixes:
            with tempfile.TemporaryDirectory(prefix='turtlegit-libgit2-verify-') as directory:
                root=pathlib.Path(directory);home=root/'home';home.mkdir();global_config=home/'config';global_config.write_text('[user]\n name = Fixture\n email = fixture@example.invalid\n');source=root/'source';clone=root/'clone'
                env=dict(os.environ,HOME=str(home),XDG_CONFIG_HOME=str(home/'xdg'),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL=str(global_config),GIT_TERMINAL_PROMPT='0')
                for key in list(env):
                    if key.startswith(('GIT_CONFIG_KEY_','GIT_CONFIG_VALUE_')) or key in ['GIT_CONFIG_PARAMETERS','GIT_CONFIG_COUNT','TURTLEGIT_LIBGIT2_ASKPASS','GIT_SSH_COMMAND']:env.pop(key,None)
                def git(*argv):return subprocess.check_output(['/usr/bin/git',*map(str,argv)],env=env,stderr=subprocess.PIPE)
                version=subprocess.check_output(prefix+[str(binary),'--version'],env=env,text=True);assert pin['libgit2']['version'] in version
                bad=subprocess.run(prefix+[str(binary),'push','--all'],env=env,capture_output=True,timeout=10);assert bad.returncode!=0 and bad.stderr
                git('init','--initial-branch=main',source);(source/'file').write_text('first\n');git('-C',source,'add','file');git('-C',source,'commit','-m','first')
                original=global_config.read_bytes()
                result=subprocess.run(prefix+[str(binary),'--no-literal-pathspecs','-C',str(root),'-c','transfer.fixture=true','clone','--progress','-v','--origin','source','--',str(source),str(clone)],env=env,capture_output=True,timeout=30);assert result.returncode==0,result.stderr.decode(errors='replace')
                assert (clone/'file').read_text()=='first\n';assert git('-C',clone,'config','--local','--get','remote.source.url').strip()==str(source).encode()
                assert subprocess.run(['/usr/bin/git','-C',clone,'config','--local','--get','transfer.fixture'],env=env,capture_output=True).returncode==1
                (source/'file').write_text('second\n');git('-C',source,'commit','-am','second');head=git('-C',clone,'rev-parse','HEAD')
                result=subprocess.run(prefix+[str(binary),'--literal-pathspecs','-C',str(clone),'fetch','--progress','--force','--','source','main:remotes/source/main'],env=env,capture_output=True,timeout=30);assert result.returncode==0,result.stderr.decode(errors='replace')
                assert git('-C',clone,'rev-parse','refs/remotes/source/main')==git('-C',source,'rev-parse','HEAD');assert git('-C',clone,'rev-parse','HEAD')==head;assert (clone/'file').read_text()=='first\n';assert global_config.read_bytes()==original
    print('LibGit2: pinned patched source, complete licences, universal macOS13 helper and SDK-only dependencies verified'+(' (structure only).' if args.structure_only else ' with actual clone/fetch.'))
if __name__=='__main__':main()
