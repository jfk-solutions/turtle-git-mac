#!/usr/bin/env python3
"""Audit the pinned universal libgit2 helper, reconstruction and SDK-only linkage."""
import argparse,base64,hashlib,json,os,pathlib,plistlib,re,shlex,shutil,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('runtime',type=pathlib.Path);parser.add_argument('--structure-only',action='store_true');parser.add_argument('--all-architectures',action='store_true');args=parser.parse_args();runtime=args.runtime.resolve()
    manifest=json.loads((runtime/'provenance.json').read_text());pin=json.loads((ROOT/'Configuration/LibGit2Runtime.json').read_text());assert manifest['pins']==pin
    assert re.fullmatch('[0-9a-f]{64}',manifest['native_cache_key'])
    assert set(manifest['native_library_sha256'])==set(pin['architectures'])
    assert all(re.fullmatch('[0-9a-f]{64}',value) for value in manifest['native_library_sha256'].values())
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
                git('init','--initial-branch=main',source);(source/'file').write_text('first\n');git('-C',source,'add','file');git('-C',source,'commit','-m','first');git('-C',source,'tag','-a','v1','-m','annotated')
                original=global_config.read_bytes()
                result=subprocess.run(prefix+[str(binary),'--no-literal-pathspecs','-C',str(root),'-c','transfer.fixture=true','clone','--progress','-v','--origin','source','--',str(source),str(clone)],env=env,capture_output=True,timeout=30);assert result.returncode==0,result.stderr.decode(errors='replace')
                assert (clone/'file').read_text()=='first\n';assert git('-C',clone,'config','--local','--get','remote.source.url').strip()==str(source).encode()
                assert subprocess.run(['/usr/bin/git','-C',clone,'config','--local','--get','transfer.fixture'],env=env,capture_output=True).returncode==1
                (source/'file').write_text('second\n');git('-C',source,'commit','-am','second');head=git('-C',clone,'rev-parse','HEAD')
                result=subprocess.run(prefix+[str(binary),'--literal-pathspecs','-C',str(clone),'fetch','--progress','--force','--','source','main:remotes/source/main'],env=env,capture_output=True,timeout=30);assert result.returncode==0,result.stderr.decode(errors='replace')
                assert git('-C',clone,'rev-parse','refs/remotes/source/main')==git('-C',source,'rev-parse','HEAD');assert git('-C',clone,'rev-parse','HEAD')==head;assert (clone/'file').read_text()=='first\n';assert global_config.read_bytes()==original
                for flags in [[],['--refs'],['-t'],['--heads']]:
                    result=subprocess.run(prefix+[str(binary),'--literal-pathspecs','-C',str(root),'ls-remote',*flags,'--',str(source)],env=env,capture_output=True,timeout=30)
                    assert result.returncode==0,result.stderr.decode(errors='replace')
                    expected=git('ls-remote',*flags,'--',source)
                    assert result.stdout==expected,(flags,result.stdout,expected)
                target=root/'target.git';git('clone','--bare',source,target)
                clone_config=(clone/'.git/config').read_bytes();clone_index=(clone/'.git/index').read_bytes()
                result=subprocess.run(prefix+[str(binary),'--literal-pathspecs','-C',str(clone),'-c','core.precomposeunicode=false','push','--',str(target),':refs/tags/v1'],env=env,capture_output=True,timeout=30)
                assert result.returncode==0,result.stderr.decode(errors='replace');assert b'[deleted]' in result.stderr
                assert subprocess.run(['/usr/bin/git','-C',target,'show-ref','--quiet','--verify','refs/tags/v1'],env=env,capture_output=True).returncode==1
                assert git('-C',source,'rev-parse','refs/tags/v1')==git('-C',clone,'rev-parse','refs/tags/v1')
                refused=subprocess.run(prefix+[str(binary),'--literal-pathspecs','-C',str(clone),'push','--',str(target),'HEAD:refs/heads/injected'],env=env,capture_output=True,timeout=10)
                assert refused.returncode!=0 and refused.stderr
                assert subprocess.run(['/usr/bin/git','-C',target,'show-ref','--quiet','--verify','refs/heads/injected'],env=env,capture_output=True).returncode==1
                assert (clone/'.git/config').read_bytes()==clone_config and (clone/'.git/index').read_bytes()==clone_index
                assert git('-C',clone,'rev-parse','HEAD')==head and (clone/'file').read_text()=='first\n' and global_config.read_bytes()==original
                # Exact historical blob bytes: builtin CRLF then an external smudge,
                # binary-check disabled, literal %f path and optional/required errors.
                literal="space 'é:historical.bin";raw=b'raw\x00historical\n'+b'x'*1_048_576
                oid=subprocess.check_output(['/usr/bin/git','-C',str(clone),'hash-object','-w','--stdin'],input=raw,env=env).strip().decode()
                (clone/'.gitattributes').write_text('*.bin filter=fixture\nprobe text eol=crlf\n')
                def materialize(path,*configuration,blob=oid):
                    argv=prefix+[str(binary),'--literal-pathspecs','-C',str(clone)]
                    for value in configuration:argv+=['-c',value]
                    return subprocess.run(argv+['cat-file','--filters','--path='+path,blob],env=env,capture_output=True,timeout=30)
                result=materialize(literal,"filter.fixture.smudge=printf '%%s\\0%%s\\0' %f %% ; cat",'filter.fixture.required=true')
                assert result.returncode==0,result.stderr.decode(errors='replace')
                assert result.stdout==literal.encode()+b'\x00%\x00'+raw
                text_oid=subprocess.check_output(['/usr/bin/git','-C',str(clone),'hash-object','-w','--stdin'],input=b'line one\nline two\n',env=env).strip().decode()
                eol=materialize('probe',blob=text_oid);assert eol.returncode==0 and eol.stdout==b'line one\r\nline two\r\n',eol.stderr
                direct=materialize('.');assert direct.returncode==0 and direct.stdout==raw,direct.stderr
                optional=materialize(literal,'filter.fixture.smudge=exit 7','filter.fixture.required=false')
                assert optional.returncode==0 and optional.stdout==raw
                required=materialize(literal,'filter.fixture.smudge=exit 7','filter.fixture.required=true')
                assert required.returncode!=0 and required.stdout==b'' and required.stderr
                missing=materialize(literal,'filter.fixture.required=true')
                assert missing.returncode!=0 and missing.stdout==b''
                assert (clone/'.git/config').read_bytes()==clone_config and (clone/'.git/index').read_bytes()==clone_index
                assert git('-C',clone,'rev-parse','HEAD')==head and global_config.read_bytes()==original
                # Real initial + recursive checkout uses the same driver with the
                # filter source repository cwd; worktree-free modes never spawn it.
                filtered=root/'filtered-source';git('init','--initial-branch=main',filtered)
                (filtered/'.gitattributes').write_text('payload filter=checkoutfixture\n')
                (filtered/'payload').write_bytes(b'checkout\x00payload\n');git('-C',filtered,'add','.');git('-C',filtered,'commit','-m','filter source')
                checkout_config="filter.checkoutfixture.smudge=pwd -P; cat"
                def clone_filtered(source,destination,*flags):
                    return subprocess.run(prefix+[str(binary),'-C',str(root),'-c',checkout_config,'-c','filter.checkoutfixture.required=true','clone','--progress',*flags,'--',str(source),str(destination)],env=env,capture_output=True,timeout=30)
                checked=root/'filtered-clone';result=clone_filtered(filtered,checked);assert result.returncode==0,result.stderr.decode(errors='replace')
                assert (checked/'payload').read_bytes()==str(checked.resolve()).encode()+b'\ncheckout\x00payload\n'
                # Actual repository configs must honor captured filenames, includes
                # and levels; transient -c alone would conceal a missing global.
                def driver_file(path,label):
                    path.write_text('[filter "checkoutfixture"]\n smudge = "printf '+label+'; cat"\n required = true\n')
                included=home/'included.config';driver_file(included,'included:')
                selected_global=home/'selected-global.config';selected_global.write_text('[include]\n path = included.config\n')
                driver_file(home/'.gitconfig','WRONG-HOME:')
                xdg=home/'xdg/git';xdg.mkdir(parents=True);driver_file(xdg/'config','WRONG-XDG:')
                def configured_clone(name,global_path,extra=(),changes=None):
                    current=dict(env,GIT_CONFIG_GLOBAL=str(global_path));current.update(changes or {})
                    destination=root/name;argv=prefix+[str(binary),'-C',str(root)]
                    for value in extra:argv+=['-c',value]
                    result=subprocess.run(argv+['clone','--',str(filtered),str(destination)],env=current,capture_output=True,timeout=30)
                    assert result.returncode==0,result.stderr.decode(errors='replace');return (destination/'payload').read_bytes()
                assert configured_clone('included-clone',selected_global)==b'included:checkout\x00payload\n'
                for name,path in [('empty-global',''),('missing-global',home/'absent-global')]:
                    assert configured_clone(name,path)==b'checkout\x00payload\n'
                template=root/'private-template';template.mkdir();driver_file(template/'config','local:')
                assert configured_clone('local-priority',selected_global,changes={'GIT_TEMPLATE_DIR':str(template)})==b'local:checkout\x00payload\n'
                assert configured_clone('app-priority',selected_global,['filter.checkoutfixture.smudge=printf app:; cat'],{'GIT_TEMPLATE_DIR':str(template)})==b'app:checkout\x00payload\n'
                system_config=home/'system.config';driver_file(system_config,'system:')
                assert configured_clone('system-override','',changes={'GIT_CONFIG_NOSYSTEM':'0','GIT_CONFIG_SYSTEM':str(system_config)})==b'system:checkout\x00payload\n'
                superproject=root/'superproject';git('init','--initial-branch=main',superproject)
                git('-C',superproject,'-c','protocol.file.allow=always','submodule','add',filtered,'nested');git('-C',superproject,'commit','-am','nested fixture')
                recursive=root/'recursive-clone';result=clone_filtered(superproject,recursive,'--recursive');assert result.returncode==0,result.stderr.decode(errors='replace')
                assert (recursive/'nested/payload').read_bytes()==str((recursive/'nested').resolve()).encode()+b'\ncheckout\x00payload\n'
                for flag,name in [('--no-checkout','without-checkout'),('--bare','bare.git')]:
                    destination=root/name;result=clone_filtered(filtered,destination,flag);assert result.returncode==0,result.stderr.decode(errors='replace')
                    assert not (destination/'payload').exists()
                assert global_config.read_bytes()==original
                # Add uses one explicitly attached private index, never the live
                # index. Clean receives that index while preserving raw disk data.
                private_index=root/'private-add-index';shutil.copyfile(clone/'.git/index',private_index);private_index.chmod(0o600)
                private_before=private_index.read_bytes();live_before=(clone/'.git/index').read_bytes()
                add_path="ignored '雪.clean";disk=b'local\x00content\r\n'
                (clone/add_path).write_bytes(disk);(clone/'.gitignore').write_text('*.clean\n')
                with (clone/'.gitattributes').open('a') as stream:stream.write('*.clean filter=addfixture -text\n')
                capture=root/'clean-index-env'
                clean="printf '%%s' \"$GIT_INDEX_FILE\" > "+shlex.quote(str(capture))+"; printf clean:; cat"
                def add_to_private(paths,mode='normal',mode_only=False,command=clean):
                    argv=prefix+[str(binary),'-C',str(clone),'-c','core.precomposeunicode=false','-c','filter.addfixture.clean='+command,'-c','filter.addfixture.required=true','add','--turtlegit-index='+str(private_index),'--turtlegit-mode='+mode,'--stdin']
                    if mode_only:argv+=['--turtlegit-mode-only']
                    return subprocess.run(argv,input=b''.join(path.encode()+b'\0' for path in paths),env=env,capture_output=True,timeout=30)
                result=add_to_private([add_path],mode='executable');assert result.returncode==0,result.stderr.decode(errors='replace')
                assert result.stdout==b'TurtleGit Add v1:'+base64.b64encode(add_path.encode())+b'\n'
                assert capture.read_bytes()==str(private_index).encode()
                staged_env=dict(env,GIT_INDEX_FILE=str(private_index))
                staged=subprocess.check_output(['/usr/bin/git','-C',str(clone),'ls-files','--stage','-z','--',add_path],env=staged_env)
                entry=staged.split(b'\t',1)[0].split();assert entry[0]==b'100755';oid=entry[1].decode()
                assert git('-C',clone,'cat-file','blob',oid)==b'clean:'+disk
                (clone/add_path).write_bytes(b'newer unstaged disk')
                result=add_to_private([add_path],mode='symlink',mode_only=True);assert result.returncode==0,result.stderr.decode(errors='replace')
                staged=subprocess.check_output(['/usr/bin/git','-C',str(clone),'ls-files','--stage','-z','--',add_path],env=staged_env)
                assert staged.split(b'\t',1)[0].split()==[b'120000',entry[1],b'0']
                saved=private_index.read_bytes();result=add_to_private([add_path],command='exit 7')
                assert result.returncode!=0 and private_index.read_bytes()==saved
                assert (clone/'.git/index').read_bytes()==live_before and (clone/add_path).read_bytes()==b'newer unstaged disk'
                assert git('-C',clone,'rev-parse','HEAD')==head and global_config.read_bytes()==original

    print('LibGit2: pinned patched source, complete licences, universal macOS13 helper and SDK-only dependencies verified'+(' (structure only).' if args.structure_only else ' with actual clone/fetch/list/deletion/historical/checkout filters and private-index Add.'))
if __name__=='__main__':main()
