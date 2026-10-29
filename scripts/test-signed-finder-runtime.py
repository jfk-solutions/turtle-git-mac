#!/usr/bin/env python3
"""Exercise actual sandboxed App Group sharing and packaged Git with an installed signing identity.
Clones are run directly, with unique QA bundle IDs; no launch/Finder service is registered.
"""
import argparse,base64,hashlib,json,os,platform,plistlib,re,signal,subprocess,sys,tempfile,threading,time,uuid
from pathlib import Path
from finder_group_identity import app_group,mach_service,query_mach_service
from native_receiver import run_receiver,signal_receiver_group
ROOT=Path(__file__).resolve().parent.parent

def metafile_request():
    """Embed captured corpus bytes: sandbox probes receive no repository paths."""
    folder=ROOT/'Tests/TurtleGitCoreTests/Fixtures/Metafile'
    red=lambda x,y:{'point':[x,y],'min':[0.8,0,0],'max':[1,0.25,0.25]}
    green=lambda x,y:{'point':[x,y],'min':[0,0.8,0],'max':[0.25,1,0.25]}
    blue=lambda x,y:{'point':[x,y],'min':[0,0,0.8],'max':[0.25,0.25,1]}
    white=lambda x,y:{'point':[x,y],'min':[0.9,0.9,0.9],'max':[1,1,1]}
    # Authored even-odd hole is unpainted; raw_scene's explicit white backdrop
    # remains opaque. Do not conflate display-on-white with decoded source RGBA.
    clear=lambda x,y:{'point':[x,y],'min':[0,0,0],'max':[0,0,0],'rgba':[0,0,0,0],'tolerance':0}
    painted_white=lambda x,y:{**white(x,y),'rgba':[255,255,255,255],'tolerance':0}
    cases=[
        {'name':'clip-vector.wmf','samples':[red(12,12),white(35,35)]},
        {'name':'classic-vector.emf','samples':[red(12,12),blue(58,12)]},
        {'name':'plus-bitmap-text.emf','samples':[red(12,12),green(28,12)],'svgContains':['Helvetica','TurtleGit','data:image/png;base64,']},
        {'name':'plus-gradient-blend.emf','samples':[red(16,24),blue(80,24),{'point':[48,24],'min':[0.35,0,0.35],'max':[1,0.25,1]}]},
        {'name':'plus-region-path.emf','samples':[red(12,12),clear(28,28),blue(64,16)]},
        {'name':'plus-hatch-atlas.emf','samples':[],'hatchCell':[2,2,8,8],'deadline':True},
        {'name':'plus-raw-indexed4-negative.emf','samples':[red(12,12),green(28,12),blue(44,12)]},
        {'name':'plus-raw-texture-rgb565-positive.emf','samples':[red(12,12),green(28,12),blue(44,12),painted_white(80,48)]},
        {'name':'unsupported-raw-palette-index.emf','samples':[],'refuse':True},
        # Recent outlined classic/WMF text exercises the actual packaged font
        # and in-process system libiconv path in the inherited sandbox.
        {'name':'classic-text-compact-low-unicode.emf','samples':[],'minInk':20,'svgContains':['<path']},
        {'name':'classic-text-poly-ansi-dx.emf','samples':[],'minInk':40,'columnRuns':3,'advance':28,'svgContains':['<path']},
        {'name':'wmf-text-dbcs-single-johab.wmf','samples':[],'minInk':30,'nativeFallback':'가','svgContains':['<path']},
        {'name':'wmf-text-ext-clip.wmf','samples':[],'minInk':1,'clipMaxX':24,'svgContains':['<path']},
        {'name':'wmf-bitmap16-bgrx32-stretch.wmf','width':64,'height':64,'samples':[red(8,8),green(12,8),blue(16,8)]},
        {'name':'wmf-bitmap16-self-bitblt-overlap.wmf','width':64,'height':64,'samples':[red(12,5),green(20,5)]},
        {'name':'unsupported-wmf-text-dbcs-johab-lead.wmf','samples':[],'refuse':True},
        {'name':'unsupported-wmf-bitmap16-bits-short.wmf','samples':[],'refuse':True},
    ]
    effects=folder/'ImageEffects'
    native=next(case for case in json.loads((effects/'windows-reference.json').read_text())['cases'] if case['file']=='state-seed.emf')
    source_sha='96eab58020dddd6c1f64f2a1b0dbb65c2e77a6f301e20b5354128df6f95bb0f7'
    raw_sha='100bd7a6901f7ce4dd60febb660b70543fd852b70234d509ee9d5948b15d43d3'
    raw=(effects/native['windowsRGBA']['file']).read_bytes()
    if native['sourceSHA256']!=source_sha or native['windowsRGBA']['sha256']!=raw_sha or hashlib.sha256(raw).hexdigest()!=raw_sha or len(raw)!=256*64*4:
        raise ValueError('Original Windows alpha oracle changed')
    alpha_samples=[]
    for x,y,expected in [(8,4,[0,0,0,0]),(8,0,[36,8,8,191]),(8,8,[8,8,8,255])]:
        offset=(y*256+x)*4
        if list(raw[offset:offset+4])!=expected:raise ValueError('Original Windows alpha point changed')
        alpha_samples.append({'point':[x,y],'min':[max(0,v-3)/255 for v in expected[:3]],'max':[min(255,v+3)/255 for v in expected[:3]],'rgba':expected,'tolerance':1})
    cases.append({'name':'state-seed.emf','samples':alpha_samples,'width':256,'height':64,'windowsRGBAHash':raw_sha})
    originals={}
    for case in cases:
        path=(effects if case['name']=='state-seed.emf' else folder)/case['name'];data=path.read_bytes();digest=hashlib.sha256(data).hexdigest();originals[path]=digest
        if case['name']=='state-seed.emf' and digest!=source_sha:raise ValueError('Original captured alpha EMF changed')
        case.update(bytes=base64.b64encode(data).decode(),sha256=digest)
        case.setdefault('width',97 if path.suffix.lower()=='.emf' else 96)
        case.setdefault('height',65 if path.suffix.lower()=='.emf' else 64)
    payload=base64.b64encode(json.dumps(cases,separators=(',',':')).encode()).decode()
    if len(payload)>192*1024:raise ValueError('Signed metafile payload exceeds bounded argv transport')
    return payload,originals

def local_tools_request():
    """Only captured bytes cross argv; the signed probe opens no checkout assets."""
    sources={'animated.gif':ROOT/'Tests/TurtleGitCoreTests/Fixtures/Metafile/compressed-raster-source-gif-two-frames.gif',
             'vector.wmf':ROOT/'Tests/TurtleGitCoreTests/Fixtures/Metafile/clip-vector.wmf'}
    originals={path:hashlib.sha256(path.read_bytes()).hexdigest() for path in sources.values()}
    packet=[{'name':name,'bytes':base64.b64encode(path.read_bytes()).decode(),'sha256':originals[path]} for name,path in sources.items()]
    payload=base64.b64encode(json.dumps(packet,separators=(',',':')).encode()).decode()
    if len(payload)>64*1024:raise ValueError('Local-tools payload exceeds bounded argv transport')
    return payload,originals

class OwnedRuntimeChildren:
    """Observe/retire only the unique disposable clone's actual helper path."""
    def __init__(self,executables,required,acknowledgements=None):
        self.executables={name:{str(path),str(path.resolve(strict=True))} for name,path in executables.items()}
        self.required=set(required);self.own_group_roles=set(executables)&{'libgit2','metafile'};self.seen={};self.errors=[];self.stop=threading.Event()
        self.acknowledgements=acknowledgements
        self.worker=threading.Thread(target=self.observe,daemon=True)
    def scan(self):
        result=subprocess.run(['/bin/ps','-axo','pid=,ppid=,pgid=,stat=,command='],capture_output=True,text=True,check=True,timeout=5)
        rows=[]
        for line in result.stdout.splitlines():
            fields=line.split(None,4)
            if len(fields)!=5:continue
            pid,parent,group=map(int,fields[:3]);rows.append((pid,parent,group,fields[3],fields[4]))
        return rows
    def roles(self,row):return [name for name,paths in self.executables.items() if any(row[4]==path or row[4].startswith(path+' ') for path in paths)]
    def owned(self,row):return bool(self.roles(row))
    def observe(self):
        try:
            while not self.stop.is_set():
                for row in self.scan():
                    if self.owned(row):
                        self.seen[row[0]]=row
                        if self.acknowledgements is not None and 'libgit2' in self.roles(row) and self.acknowledgements.is_dir():
                            acknowledgement=self.acknowledgements/('observed-libgit2-'+str(row[0])+'.json')
                            if not acknowledgement.exists():
                                staged=acknowledgement.with_suffix('.tmp')
                                staged.write_text(json.dumps({'pid':row[0],'pgid':row[2]}))
                                staged.replace(acknowledgement)
                self.stop.wait(0.01)
        except Exception as error:self.errors.append(str(error))
    def __enter__(self):self.worker.start();return self
    def __exit__(self,kind,value,traceback):
        self.stop.set();self.worker.join(timeout=6)
        if self.worker.is_alive():raise RuntimeError('Owned helper observer did not drain')
        leftovers=[row for row in self.scan() if self.owned(row) and not row[3].startswith('Z')]
        needed_cleanup=bool(leftovers)
        for row in leftovers:
            self.seen[row[0]]=row
            # Revalidate the unique executable before signalling; do not act on
            # an old observed PID which could have been reused by another task.
            live=next((item for item in self.scan() if item[0]==row[0] and self.owned(item)),None)
            if live:
                try:os.killpg(live[2],signal.SIGKILL) if live[2]==live[0] else os.kill(live[0],signal.SIGKILL)
                except ProcessLookupError:pass
        deadline=time.monotonic()+5
        while leftovers and time.monotonic()<deadline:
            leftovers=[row for row in self.scan() if self.owned(row) and not row[3].startswith('Z')]
            if leftovers:time.sleep(0.02)
        groups_drained=not any(signal_receiver_group(row[2],0) for row in self.seen.values())
        pids_drained=not any(row[0] in self.seen for row in self.scan())
        self.result={'observed_helper_processes':len(self.seen),'owned_helper_pids':[row[0] for row in self.seen.values()],
                     'owned_helper_groups':[row[2] for row in self.seen.values()],
                     'observed_helper_roles':{name:sum(name in self.roles(row) for row in self.seen.values()) for name in self.executables},
                     'own_process_group_required_roles':sorted(self.own_group_roles),
                     'observed_processes':[{'pid':row[0],'ppid':row[1],'pgid':row[2],'roles':self.roles(row)} for row in self.seen.values()],
                     'helper_processes_and_groups_drained':not leftovers and groups_drained and pids_drained,'forced_cleanup_needed':needed_cleanup,'observer_errors':self.errors}
        if leftovers and kind is None:raise RuntimeError('Owned signed runtime helper survived cleanup')
        if kind is None:
            if needed_cleanup:raise RuntimeError('Signed runtime helper outlived its parent request and required cleanup')
            if self.errors:raise RuntimeError('Cannot verify helper process ownership: '+'; '.join(self.errors))
            if any(not any(name in self.roles(row) for row in self.seen.values()) for name in self.required):raise RuntimeError('No actual packaged helper execution observed for required roles: '+', '.join(sorted(self.required)))
            # Git can start own-image maintenance children in its accepted
            # request group. Direct libgit2/metafile helpers own their groups.
            if any(row[0]!=row[2] and self.own_group_roles.intersection(self.roles(row)) for row in self.seen.values()):raise RuntimeError('Direct runtime helper did not own its process group')
            if not groups_drained:raise RuntimeError('Owned runtime helper process group did not drain')
            if not pids_drained:raise RuntimeError('Owned runtime helper PID did not drain')

def signature(path):
    result=subprocess.run(['/usr/bin/codesign','-dv','--verbose=4',str(path)],capture_output=True,text=True,check=True)
    match=re.search(r'^TeamIdentifier=([A-Z0-9]{10})$',result.stderr,re.M)
    if not match:raise ValueError('An actual Apple developer signature is required: '+str(path))
    return match.group(1)

def entitlements(path):
    data=subprocess.check_output(['/usr/bin/codesign','-d','--entitlements',':-',str(path)],stderr=subprocess.PIPE)
    return plistlib.loads(data)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app',type=Path);parser.add_argument('--team',required=True)
    parser.add_argument('--only',choices=('history','metafile','unified-diff','udiff','local-tools'),action='append',help='Focused runtime retry; independent App Group evidence is recorded by the complete run.')
    parser.add_argument('--skip-metafile',action='store_true',help='Run App Group, history and Unified Diff phases without unchanged metafile coverage.')
    parser.add_argument('--identity',required=True,help='Installed Apple Development signing identity SHA-1.')
    parser.add_argument('--report',required=True,type=Path);args=parser.parse_args()
    if args.skip_metafile and args.only:parser.error('--skip-metafile cannot be combined with --only')
    group=app_group(args.team);app=args.app.resolve(strict=True)
    if not re.fullmatch(r'[A-Fa-f0-9]{40}',args.identity):raise ValueError('Use an explicit installed identity SHA-1.')
    subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True)
    peers=[(app,'org.turtlegit.macos'),(app/'Contents/PlugIns/TurtleGitFinder.appex','org.turtlegit.macos.finder'),(app/'Contents/Library/LaunchServices/TurtleGitCache.app','org.turtlegit.macos.cache')]
    for peer,identifier in peers:
        if signature(peer)!=args.team:raise ValueError('Peer signing teams differ')
        value=entitlements(peer)
        if value.get('com.apple.security.app-sandbox') is not True or value.get('com.apple.security.application-groups') != [group]:
            raise ValueError('Peer sandbox/group entitlements differ: '+str(peer))
        requirement='anchor apple generic and identifier "'+identifier+'" and certificate leaf[subject.OU] = "'+args.team+'"'
        subprocess.run(['/usr/bin/codesign','--verify','-R','='+requirement,str(peer)],check=True)
    launch=plistlib.loads((app/'Contents/Library/LaunchAgents/org.turtlegit.macos.cache.plist').read_bytes())
    if launch.get('MachServices')!={mach_service(args.team):True,query_mach_service(args.team):True}:raise ValueError('Packaged service namespace differs')
    git=(app/'Contents/Helpers/Git/bin/git').resolve(strict=True)
    git_rights=entitlements(git)
    if signature(git)!=args.team or not all(git_rights.get(key) is True for key in ['com.apple.security.app-sandbox','com.apple.security.inherit']):
        raise ValueError('Packaged Git lacks same-team inherited sandbox signing')
    metafile_home=app/'Contents/Helpers/Metafile';metafile=(metafile_home/'metafile-convert').resolve(strict=True)
    if metafile.parent!=app/'Contents/MacOS' or not (metafile_home/'renderer.js').is_file():raise ValueError('Packaged Metafile runtime escaped signed MacOS layout or is incomplete')
    metafile_rights=entitlements(metafile)
    if signature(metafile)!=args.team or not all(metafile_rights.get(key) is True for key in ['com.apple.security.app-sandbox','com.apple.security.inherit']):
        raise ValueError('Packaged Metafile lacks same-team inherited sandbox signing')
    libgit2_home=app/'Contents/Helpers/LibGit2';libgit2=(libgit2_home/'bin/turtlegit-libgit2').resolve(strict=True)
    if libgit2.parent!=app/'Contents/MacOS':raise ValueError('Packaged LibGit2 escaped signed MacOS layout')
    libgit2_rights=entitlements(libgit2)
    if signature(libgit2)!=args.team or not all(libgit2_rights.get(key) is True for key in ['com.apple.security.app-sandbox','com.apple.security.inherit']):
        raise ValueError('Packaged LibGit2 lacks same-team inherited sandbox signing')
    source=ROOT/'docs/qa/signed-finder-runtime-probe-2026-10-17.swift'
    products=app.parent
    record={'requested_runtime_phases':args.only or (['app-group','history','unified-diff'] if args.skip_metafile else ['app-group','history','metafile','unified-diff']),'team':args.team,'group':group,'app':str(app),'actual_peer_signatures':3,'packaged_git_inherits_sandbox':True,'packaged_metafile_inherits_sandbox':True,'packaged_libgit2_inherits_sandbox':True,'cases':[],'finder_activation':'not performed','service_registration':'not performed'}
    framework=app/'Contents/Frameworks/TurtleGitCore.framework/TurtleGitCore'
    record['packaged_core_sha256']=hashlib.sha256(framework.read_bytes()).hexdigest()
    record['probe_source_sha256']=hashlib.sha256(source.read_bytes()).hexdigest()
    try:
        with tempfile.TemporaryDirectory(prefix='signed-finder-',dir=ROOT/'build/qa') as temporary:
            folder=Path(temporary);binary=folder/'probe'
            subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5','-target',platform.machine()+'-apple-macos13.0','-F',str(products),'-framework','TurtleGitCore','-Xlinker','-rpath','-Xlinker','@executable_path/../Frameworks',str(source),'-o',str(binary)],check=True)
            clones=[]
            for allowed in [True,False]:
                clone=folder/('Allowed.app' if allowed else 'Denied.app')
                subprocess.run(['/usr/bin/ditto',str(app),str(clone)],check=True)
                # Only these disposable copies change; keep the shipping code/resources intact.
                info_path=clone/'Contents/Info.plist';info=plistlib.loads(info_path.read_bytes())
                info['CFBundleIdentifier']='org.turtlegit.macos.documentation-preview.signed-'+uuid.uuid4().hex
                info['CFBundleName']='TurtleGit Signed Runtime QA'
                for key in ['CFBundleURLTypes','CFBundleDocumentTypes','UTExportedTypeDeclarations','UTImportedTypeDeclarations']:info.pop(key,None)
                info_path.write_bytes(plistlib.dumps(info))
                subprocess.run(['/bin/cp',str(binary),str(clone/'Contents/MacOS'/info['CFBundleExecutable'])],check=True)
                profile=clone/'Contents/embedded.provisionprofile'
                if profile.exists():profile.unlink()
                rights={'com.apple.security.app-sandbox':True}
                if allowed:rights['com.apple.security.application-groups']=[group]
                permissions=folder/('allowed.plist' if allowed else 'denied.plist');permissions.write_bytes(plistlib.dumps(rights))
                subprocess.run(['/usr/bin/codesign','--force','--sign',args.identity,'--options','runtime','--timestamp=none','--entitlements',str(permissions),str(clone)],check=True)
                subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(clone)],check=True)
                clones.append(clone/'Contents/MacOS'/info['CFBundleExecutable'])
            environment=os.environ.copy();environment.update(GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
            environment.pop('DYLD_FRAMEWORK_PATH',None);environment.pop('DYLD_LIBRARY_PATH',None)
            environment.pop('GIT_CONFIG_PARAMETERS',None)
            for key in list(environment):
                if key.startswith(('GIT_CONFIG_KEY_','GIT_CONFIG_VALUE_')):environment.pop(key)
            identifier=str(uuid.uuid4());snapshot=None
            local_tools_only=args.only is not None and set(args.only)=={'local-tools'}
            def run(binary,mode,*extra):
                child_environment=environment
                if mode=='local-tools':
                    child_environment={key:value for key,value in environment.items() if not key.startswith('GIT_')}
                    child_environment.update(GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',GIT_TERMINAL_PROMPT='0')
                result=run_receiver([str(binary),mode,identifier,args.team,*extra],cwd=ROOT,env=child_environment,capture_output=True,text=True,timeout=90)
                print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
                lines=[line for line in result.stdout.splitlines() if line.startswith('TURTLEGIT_SIGNED_QA ')]
                if len(lines)!=1:raise ValueError('Signed probe did not complete')
                value=json.loads(lines[0].split(' ',1)[1])
                if value.get('passed') is not True:raise ValueError('Signed probe reported failure: '+mode)
                record['cases'].append(value)
                return value
            try:
                if args.only is None:
                    snapshot=run(clones[0],'writer')['snapshot']
                    record['packaged_lexilla_runs_from_sandbox']=True
                    run(clones[0],'reader')
                    run(clones[1],'denied',snapshot)
                elif not local_tools_only:
                    snapshot=run(clones[0],'location')['snapshot']
                if args.only is None or 'history' in args.only:
                    history_children=OwnedRuntimeChildren({'libgit2':clones[0].parent.parent/'Helpers/LibGit2/bin/turtlegit-libgit2','git':clones[0].parent.parent/'Helpers/Git/bin/git'},required={'libgit2'},acknowledgements=Path(snapshot).parent)
                    try:
                        with history_children:
                            receipt=run(clones[0],'history')
                            if receipt.get('outside_file_grants') is not False or receipt.get('shipping_gui_launched') is not False:raise ValueError('History probe escaped owned sandbox-only scope')
                            history=receipt.get('history',{})
                            for key in ['literal_references_distinct','browser_pinned','notes_empty','configured_signature','head_unchanged','index_unchanged','config_unchanged','working_unchanged']:
                                if history.get(key) is not True:raise ValueError('History probe missing completed assertion: '+key)
                            if history.get('notes_engine')!='libgit2' or history.get('notes_ref')!='refs/notes/signed-qa':raise ValueError('History probe did not use the source Notes engine/ref')
                            observed=history.get('observed_notes_read',{})
                            if any(observed.get(key) is not True for key in ['os_observed','valid_notes_read_reply','reaped']):raise ValueError('History Notes observation handshake did not finish')
                            if observed.get('pid') not in history_children.seen or observed.get('pgid')!=observed.get('pid'):raise ValueError('History Notes helper receipt differs from independent OS observation')
                            if not isinstance(history.get('notes_utf8_bytes'),int) or history['notes_utf8_bytes']<1_000_000 or not re.fullmatch('[0-9a-f]{64}',history.get('notes_sha256','')):raise ValueError('History exact Notes payload receipt is incomplete')
                            for key in ['head','tree','raw_tag_oid','gitlink_oid']:
                                if not re.fullmatch('[0-9a-f]{40}',history.get(key,'')):raise ValueError('History object receipt is incomplete: '+key)
                            for key,path in [('git',clones[0].parent.parent/'Helpers/Git/bin/git'),('libgit2',clones[0].parent.parent/'Helpers/LibGit2/bin/turtlegit-libgit2')]:
                                if Path(history.get(key,'')).resolve()!=path.resolve(strict=True):raise ValueError('History probe used an external runtime: '+key)
                    finally:
                        if hasattr(history_children,'result'):record['history_children']=history_children.result
                    record['packaged_history_and_notes_run_from_sandbox']=True
                if args.only is None or 'unified-diff' in args.only:
                    receipt=run(clones[0],'unified-diff')
                    value=receipt.get('unified_diff',{})
                    for key in ['rectangle_cut_raw_bytes','whole_line_duplicate','value_undo_redo','byte_only_transpose_dirty','sandbox_save_reload']:
                        if value.get(key) is not True:raise ValueError('Signed Unified Diff missing assertion: '+key)
                    if value.get('native_ui_executed') is not False or receipt.get('outside_file_grants') is not False or receipt.get('shipping_gui_launched') is not False:
                        raise ValueError('Signed Unified Diff scope receipt is incorrect')
                    for key in ['input_sha256','saved_sha256','byte_only_sha256']:
                        if not re.fullmatch('[0-9a-f]{64}',value.get(key,'')):raise ValueError('Signed Unified Diff byte receipt is incomplete')
                    record['packaged_unified_diff_core_runs_from_sandbox']=True
                    record['unified_diff_native_ui']='not exercised; separate native receiver covers TextKit/gestures/NSUndoManager'
                if args.only and 'udiff' in args.only:
                    receipt=run(clones[0],'udiff')
                    value=receipt.get('udiff',{})
                    for key in ['public_core_package_smoke','navigation_boundaries','selection_case_and_rectangle','opaque_legacy_bom_bytes','source_codec_nfd']:
                        if value.get(key) is not True:raise ValueError('Signed public UDiff smoke missing '+key)
                    if any(value.get(key) is not False for key in ['native_ui_executed','helpers_executed']) or any(receipt.get(key) is not False for key in ['outside_file_grants','shipping_gui_launched','app_group_files_created']):raise ValueError('Signed public UDiff smoke escaped pure private scope')
                    for key in ['input_sha256','edited_sha256','legacy_sha256']:
                        if not re.fullmatch('[0-9a-f]{64}',value.get(key,'')):raise ValueError('Signed public UDiff byte receipt incomplete')
                    if len(value.get('codec_sha256',{}))!=3 or any(not re.fullmatch('[0-9a-f]{64}',digest) for digest in value['codec_sha256'].values()):raise ValueError('Signed public UDiff codec receipt incomplete')
                    record['packaged_udiff_public_core_smoke']=True
                    record['udiff_native_ui']='not exercised; source-linked private native receiver is separate'
                if args.only and 'local-tools' in args.only:
                    payload,originals=local_tools_request()
                    # No App Group entitlement is present on this disposable parent.
                    local_binary=clones[1]
                    clone_core=local_binary.parent.parent/'Frameworks/TurtleGitCore.framework/TurtleGitCore'
                    if hashlib.sha256(clone_core.read_bytes()).hexdigest()!=record['packaged_core_sha256']:raise ValueError('Local-tools clone changed production Core')
                    children=OwnedRuntimeChildren({'git':local_binary.parent.parent/'Helpers/Git/bin/git'},required={'git'})
                    try:
                        with children:
                            receipt=run(local_binary,'local-tools',payload)
                            value=receipt.get('local_tools',{})
                            for key in ['public_core_package_smoke','image_original_bytes_selection','raw_folder_archive','raw_individual_materialization','captured_revision_backend','head_index_working_unchanged']:
                                if value.get(key) is not True:raise ValueError('Signed local-tools smoke missing '+key)
                            if value.get('native_ui_executed') is not False or any(receipt.get(key) is not False for key in ['outside_file_grants','shipping_gui_launched','app_group_files_created']) or receipt.get('private_container_cleaned') is not True:raise ValueError('Signed local-tools scope/cleanup incorrect')
                            if Path(value.get('git','')).resolve()!= (local_binary.parent.parent/'Helpers/Git/bin/git').resolve(strict=True):raise ValueError('Local-tools used external Git')
                            if set(value.get('image_sha256',{}))!={'animated.gif','vector.wmf','opaque.bin'}:raise ValueError('Local-tools image byte receipts incomplete')
                            expected_images={name:originals[path] for name,path in {'animated.gif':ROOT/'Tests/TurtleGitCoreTests/Fixtures/Metafile/compressed-raster-source-gif-two-frames.gif','vector.wmf':ROOT/'Tests/TurtleGitCoreTests/Fixtures/Metafile/clip-vector.wmf'}.items()}
                            if any(value['image_sha256'].get(name)!=digest for name,digest in expected_images.items()):raise ValueError('Signed image smoke changed original containers')
                            for key in ['archive_sha256','raw_blob_sha256']:
                                if not re.fullmatch('[0-9a-f]{64}',value.get(key,'')):raise ValueError('Local-tools byte receipt missing '+key)
                    finally:
                        if hasattr(children,'result'):record['local_tools_children']=children.result
                    if hashlib.sha256(clone_core.read_bytes()).hexdigest()!=record['packaged_core_sha256']:raise ValueError('Local-tools changed production Core during execution')
                    for path,digest in originals.items():
                        if hashlib.sha256(path.read_bytes()).hexdigest()!=digest:raise ValueError('Local-tools changed original image asset')
                    record['packaged_local_tools_public_core_smoke']=True
                    record['local_tools_native_ui']='not exercised; separate private native receiver covers controls and delivery'
                    record['local_tools_app_group_entitled']=False
                if not args.skip_metafile and (args.only is None or 'metafile' in args.only):
                    payload,originals=metafile_request()
                    children=OwnedRuntimeChildren({'metafile':clones[0].parent.parent/'Helpers/Metafile/metafile-convert'},required={'metafile'})
                    try:
                        with children:
                            receipt=run(clones[0],'metafile',payload)
                            images=receipt.get('images',[])
                            expected={path.name:digest for path,digest in originals.items()}
                            if len(images)!=len(expected) or {image.get('name') for image in images}!=set(expected):raise ValueError('Signed metafile receipt lost required cases')
                            for image in images:
                                if image.get('source_sha256')!=expected[image['name']]:raise ValueError('Signed metafile receipt changed captured bytes')
                                for key in ['source_bytes_unchanged','private_decoder_directories_removed']:
                                    if image.get(key) is not True:raise ValueError('Signed metafile receipt lacks '+key)
                            alpha=next(image for image in images if image['name']=='state-seed.emf')
                            if alpha.get('source_alpha_retained') is not True or alpha.get('windows_rgba_sha256')!='100bd7a6901f7ce4dd60febb660b70543fd852b70234d509ee9d5948b15d43d3':raise ValueError('Signed source-alpha proof missing original Windows oracle')
                            observed={(tuple(item.get('point',[])),tuple(item.get('original_windows_rgba',[]))) for item in alpha.get('samples',[])}
                            if observed!={((8,4),(0,0,0,0)),((8,0),(36,8,8,191)),((8,8),(8,8,8,255))}:raise ValueError('Signed source-alpha receipt lost transparent/partial/opaque points')
                            johab=next(image for image in images if image['name']=='wmf-text-dbcs-single-johab.wmf')
                            if johab.get('native_fallback_outline') is not True or johab.get('fallback_coverage',0)<=0.9:raise ValueError('Signed Johab did not paint the actual native fallback outline')
                    finally:
                        if hasattr(children,'result'):record['metafile_children']=children.result
                    record['packaged_metafile_runs_from_sandbox']=True
                    for path,digest in originals.items():
                        if hashlib.sha256(path.read_bytes()).hexdigest()!=digest:raise ValueError('Signed probe changed original metafile fixture: '+path.name)
                    record['metafile_fixture_files_unchanged']=True
            finally:
                original_error=sys.exc_info()[1]
                try:
                    if not local_tools_only:run(clones[0],'cleanup')
                except BaseException as error:
                    record['cleanup_error']=str(error)
                    if original_error is None:raise
        record['passed']=True
    except BaseException as error:
        record['passed']=False;record['failure']=str(error)
        raise
    finally:
        args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(record,indent=2)+'\n')
    print('PASS signed runtime: requested sandbox phases completed with owned helper cleanup. No installed Finder activation.')

if __name__=='__main__':main()
