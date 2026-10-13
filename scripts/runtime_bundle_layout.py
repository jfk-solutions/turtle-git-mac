"""Shared containment and replacement rules for packaged runtime code/data."""
import hashlib,json,os,pathlib,shutil
MACH={bytes.fromhex(v) for v in ['cffaedfe','feedfacf','cafebabe','bebafeca']}
def remove_entry(path):
    path=pathlib.Path(path)
    if path.is_symlink() or path.is_file():path.unlink()
    elif path.exists():shutil.rmtree(path)
def bundle_for_runtime(runtime):
    for parent in pathlib.Path(runtime).resolve().parents:
        if parent.suffix=='.app' and (parent/'Contents/Info.plist').is_file():return parent
    return None
def code_record(path,runtime):
    app=bundle_for_runtime(runtime)
    if not app:return None
    descriptor=app/'Contents/Resources/runtime-layout.json'
    if not descriptor.is_file():return None
    layout=json.loads(descriptor.read_text());assert layout['version']==1
    path=pathlib.Path(path)
    logical=path.parent.resolve()/path.name
    try:key=str(logical.relative_to(app/'Contents'))
    except ValueError:return None
    record=layout['code'].get(key)
    alias=layout.get('aliases',{}).get(key)
    if alias:
        assert os.readlink(path)==alias['link']
        record=dict(layout['code'][alias['code']],alias=True)
    if not record:return None
    target=app/'Contents'/record['destination']
    assert '..' not in pathlib.Path(record['destination']).parts
    assert record['destination'].startswith(('MacOS/TurtleGitRuntime-','Frameworks/TurtleGitRuntimeLibraries/'))
    assert path.is_symlink() and path.resolve()==target.resolve() and target.is_file()
    assert hashlib.sha256(target.read_bytes()).hexdigest()==record['sha256']
    return record

def audit_layout(app):
    """Audit every declared code alias, standard placement and native dependency."""
    import subprocess, struct
    from git_lfs_runtime import slices
    contents=pathlib.Path(app).resolve()/'Contents'
    layout=json.loads((contents/'Resources/runtime-layout.json').read_text())
    assert layout['version']==1 and layout['code']
    destinations={record['destination']:key for key,record in layout['code'].items()}
    assert len(destinations)==len(layout['code']), 'Duplicate runtime code destination'
    for name in layout['runtimes']:
        assert pathlib.Path(name).name==name
        alias=contents/'Helpers'/name
        assert alias.is_symlink() and alias.resolve()==contents/'Resources/TurtleGitRuntimes'/name
    for key,record in layout['code'].items():
        assert '..' not in pathlib.Path(key).parts and key.startswith('Resources/TurtleGitRuntimes/')
        logical=contents/key
        assert code_record(logical,logical.parent)==record
        target=contents/record['destination']
        kinds={struct.unpack_from('<I',data,12)[0] for data in slices(target.read_bytes()).values()}
        assert kinds=={record['kind']}
        assert record['destination'].startswith('MacOS/') if kinds=={2} else record['destination'].startswith('Frameworks/')
        subprocess.run(['codesign','--verify','--strict',str(target)],check=True,capture_output=True)
        # Inspect load commands directly: otool -L includes a dylib's own ID.
        for arch,data in slices(target.read_bytes()).items():
            cursor=32; rpaths=[]; dependencies=[]
            for _ in range(struct.unpack_from('<I',data,16)[0]):
                command,size=struct.unpack_from('<II',data,cursor)
                if command in {12,0x80000018,0x8000001f,0x80000023,0x8000001c}:
                    offset=struct.unpack_from('<I',data,cursor+8)[0]
                    value=data[cursor+offset:cursor+size].split(b'\0',1)[0].decode()
                    (rpaths if command==0x8000001c else dependencies).append(value)
                cursor+=size
            for dependency in dependencies:
                if dependency.startswith(('/usr/lib/','/System/Library/')):continue
                assert dependency.startswith('@rpath/'),(key,dependency)
                destination='Frameworks/TurtleGitRuntimeLibraries/'+dependency[len('@rpath/'):]
                assert destination in destinations,(key,dependency)
                assert arch in slices((contents/destination).read_bytes()), 'Cross-architecture dependency'
                expected='@executable_path/../Frameworks/TurtleGitRuntimeLibraries' if record['kind']==2 else '@loader_path'
                assert expected in rpaths,(key,rpaths)
    for path in (contents/'Resources/TurtleGitRuntimes').rglob('*'):
        if path.is_symlink():
            assert path.resolve().is_relative_to(contents)
            if not path.resolve().is_relative_to(contents/'Resources/TurtleGitRuntimes'):
                assert code_record(path,path.parent)
        elif path.is_file():
            with path.open('rb') as stream:assert stream.read(4) not in MACH, 'Native code in resources: '+str(path)
    actual={str(p.relative_to(contents)) for directory in [contents/'MacOS',contents/'Frameworks/TurtleGitRuntimeLibraries'] for p in directory.glob('TurtleGitRuntime-*') if p.is_file()}
    assert actual==set(destinations), 'Unowned/missing runtime code'
    return len(destinations)
