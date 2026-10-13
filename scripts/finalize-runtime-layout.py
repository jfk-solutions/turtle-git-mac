#!/usr/bin/env python3
"""Place production runtime code/data correctly, fix linkage and sign inside out."""
import hashlib,json,os,pathlib,shutil,struct,subprocess,sys
from git_lfs_runtime import slices
from runtime_bundle_layout import MACH,remove_entry
ROOT=pathlib.Path(__file__).resolve().parent.parent
app=pathlib.Path(sys.argv[1]).resolve();contents=app/'Contents'
assert app.suffix=='.app' and (contents/'Info.plist').is_file()
helpers=contents/'Helpers';resources=contents/'Resources/TurtleGitRuntimes';libraries=contents/'Frameworks/TurtleGitRuntimeLibraries'
resources.mkdir(parents=True,exist_ok=True);libraries.mkdir(parents=True,exist_ok=True)
identity=os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') if os.environ.get('CODE_SIGNING_ALLOWED')=='YES' else '-'
assert identity,'Missing runtime signing identity'
inherited=os.environ.get('CODE_SIGNING_ALLOWED')=='YES' and os.environ.get('CONFIGURATION')=='AppStore'
def metadata(path):
    kinds=set();references=set();identifiers=set();rpaths=set()
    for data in slices(path.read_bytes()).values():
        kinds.add(struct.unpack_from('<I',data,12)[0]);count=struct.unpack_from('<I',data,16)[0];cursor=32
        for _ in range(count):
            command,size=struct.unpack_from('<II',data,cursor)
            if command in [12,13,0x80000018,0x8000001f,0x80000023,0x8000001c]:
                offset=struct.unpack_from('<I',data,cursor+8)[0];value=data[cursor+offset:cursor+size].split(b'\0',1)[0].decode()
                if command==13:identifiers.add(value)
                elif command==0x8000001c:rpaths.add(value)
                else:references.add(value)
            cursor += size
    assert len(kinds)==1 and kinds <= {2,6,8},path
    return kinds.pop(),references,identifiers,rpaths
# Inventory all original locations before moving anything; linker-relative paths
# must resolve against the original layout, including existing library symlinks.
records={};mapping={};trees=[]
for runtime in sorted(helpers.iterdir()):
    if runtime.is_symlink():continue
    assert runtime.is_dir(),runtime
    trees.append(runtime)
    for path in runtime.rglob('*'):
        if path.is_file() and not path.is_symlink():
            with path.open('rb') as stream:is_code=stream.read(4) in MACH
            if not is_code:continue
            kind,refs,ids,rpaths=metadata(path);relative=path.relative_to(runtime)
            name='TurtleGitRuntime-'+runtime.name+'-'+hashlib.sha256(str(relative).encode()).hexdigest()[:12]+'-'+path.name
            destination=contents/'MacOS'/name if kind==2 else libraries/name
            item={'source':path,'runtime':runtime,'relative':relative,'kind':kind,'references':refs,'ids':ids,'rpaths':rpaths,'destination':destination,'original_sha256':hashlib.sha256(path.read_bytes()).hexdigest()}
            records[path]=item;mapping[path.resolve()]=item
aliases={}
for runtime in trees:
    for path in runtime.rglob('*'):
        if path.is_symlink() and path.resolve() in mapping:
            primary=mapping[path.resolve()]
            key=str(pathlib.Path('Resources/TurtleGitRuntimes')/runtime.name/path.relative_to(runtime))
            aliases[key]={'code':str(pathlib.Path('Resources/TurtleGitRuntimes')/primary['runtime'].name/primary['relative']),'link':os.readlink(path)}
for path,item in records.items():
    changes={}
    for reference in item['references']:
        if reference.startswith(('/usr/lib/','/System/Library/')):continue
        if reference.startswith('@loader_path/'):
            target=(path.parent/reference[len('@loader_path/'):]).resolve()
        elif reference.startswith('@rpath/'):
            candidates=[]
            for rpath in item['rpaths']:
                if rpath.startswith('@loader_path'):candidates.append((path.parent/rpath[len('@loader_path'):].lstrip('/')/reference[len('@rpath/'):]).resolve())
            found=[p for p in candidates if p in mapping];assert len(set(found))==1,(path,reference);target=found[0]
        else:raise RuntimeError('Unsupported non-system linkage: '+str(path)+' '+reference)
        assert target in mapping,(path,reference,target)
        dependency=mapping[target];assert dependency['kind'] in {6,8}
        changes[reference]='@rpath/'+dependency['destination'].name
    item['changes']=changes
# A finalized bundle can be re-audited without deleting its live code. A partial
# refresh is rejected: stale and fresh runtime trees must never be combined.
old=contents/'Resources/runtime-layout.json'
if old.exists():
    previous=json.loads(old.read_text())
    if not trees:
        from runtime_bundle_layout import audit_layout
        print('Production layout already finalized:',audit_layout(app));sys.exit(0)
    assert set(previous['runtimes']) <= {p.name for p in trees}, 'Re-embed all runtimes before finalizing'
# Remove only files owned by an earlier layout descriptor, then replace trees.
old=contents/'Resources/runtime-layout.json'
if old.exists():
    previous=json.loads(old.read_text());assert previous['version']==1
    for record in previous['code'].values():
        name=record['destination'];assert '..' not in pathlib.Path(name).parts and name.startswith(('MacOS/TurtleGitRuntime-','Frameworks/TurtleGitRuntimeLibraries/'))
        remove_entry(contents/name)
for runtime in trees:
    target=resources/runtime.name;remove_entry(target);shutil.move(str(runtime),target)
    runtime.symlink_to('../Resources/TurtleGitRuntimes/'+runtime.name)
output={}
for original,item in records.items():
    logical=resources/item['runtime'].name/item['relative'];destination=item['destination'];destination.parent.mkdir(parents=True,exist_ok=True)
    shutil.move(str(logical),destination)
    command=['install_name_tool']
    for before,after in item['changes'].items():command += ['-change',before,after]
    if item['kind']==6:command += ['-id','@rpath/'+destination.name]
    if item['changes']:
        for rpath in item['rpaths']:command += ['-delete_rpath',rpath]
        command += ['-add_rpath','@executable_path/../Frameworks/TurtleGitRuntimeLibraries' if item['kind']==2 else '@loader_path']
    if len(command)>1:subprocess.run(command+[str(destination)],check=True)
    signing=['codesign','--force','--sign',identity]
    if identity!='-':signing += ['--options','runtime']
    if inherited and item['kind']==2:signing += ['--entitlements',str(ROOT/'Configuration/GitHelper.entitlements')]
    subprocess.run(signing+[str(destination)],check=True)
    logical.symlink_to(os.path.relpath(destination,logical.parent))
    output[str(logical.relative_to(contents))]={'destination':str(destination.relative_to(contents)),'sha256':hashlib.sha256(destination.read_bytes()).hexdigest(),'original_sha256':item['original_sha256'],'kind':item['kind'],'linkage_changes':item['changes'],'sandbox_inherited':inherited and item['kind']==2}
# The installed SVN manifest records the relocated bytes and retains originals.
svn=resources/'Git/share/licenses/git-svn/runtime-manifest.json'
if svn.is_file():
    manifest=json.loads(svn.read_text());manifest.setdefault('unsigned_files_sha256',manifest['files_sha256'].copy())
    for relative in manifest['files_sha256']:
        manifest['files_sha256'][relative]=hashlib.sha256((resources/'Git'/relative).read_bytes()).hexdigest()
    manifest['bundle_layout']=1;svn.write_text(json.dumps(manifest,indent=2)+'\n')
# Keep each existing provenance format truthful after relocation/re-signing.
for runtime in trees:
    target=resources/runtime.name;file=target/'provenance.json'
    if not file.exists():continue
    manifest=json.loads(file.read_text())
    names={'GitAskpass':'TurtleGitGitAskpass','EditorConfig':'editorconfig','IssueRegex':'issue-regex','MergeDiff':'merge-diff','GraphLayout':'graph-layout','SSHAskpass':'TurtleGitSSHAskpass'}
    if runtime.name in names:
        binary=target/names[runtime.name];manifest.setdefault('unsigned_binary_sha256',manifest['binary_sha256']);manifest['binary_sha256']=hashlib.sha256(binary.read_bytes()).hexdigest()
    elif runtime.name=='Lexilla':
        manifest.setdefault('unsigned_binary_sha256',manifest['files']['lexilla']);manifest['files']['lexilla']=hashlib.sha256((target/'lexilla').read_bytes()).hexdigest()
    elif runtime.name=='OpenSSH':
        manifest.setdefault('unsigned_binary_sha256',manifest['binary_sha256'].copy())
        for name in manifest['binary_sha256']:
            digest=hashlib.sha256((target/'bin'/name).read_bytes()).hexdigest();manifest['binary_sha256'][name]=digest;manifest['files_sha256']['bin/'+name]=digest
    manifest['signed']=True;manifest['sandbox_inherited']=inherited;manifest['bundle_layout']=1
    file.write_text(json.dumps(manifest,indent=2)+'\n')
(contents/'Resources/runtime-layout.json').write_text(json.dumps({'version':1,'code':output,'aliases':aliases,'runtimes':[p.name for p in trees]},indent=2)+'\n')
from runtime_bundle_layout import audit_layout
assert audit_layout(app)==len(output)
print('Production layout: '+str(len(output))+' runtime code items separated from data; inherited sandbox='+str(inherited))
