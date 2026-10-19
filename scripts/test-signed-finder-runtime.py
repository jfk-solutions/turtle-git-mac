#!/usr/bin/env python3
"""Exercise actual sandboxed App Group sharing and packaged Git with an installed signing identity.
Clones are run directly, with unique QA bundle IDs; no launch/Finder service is registered.
"""
import argparse,base64,hashlib,json,os,platform,plistlib,re,signal,subprocess,tempfile,threading,time,uuid
from pathlib import Path
from finder_group_identity import app_group,mach_service
from native_receiver import run_receiver,signal_receiver_group
ROOT=Path(__file__).resolve().parent.parent

def metafile_request():
    """Embed captured corpus bytes: sandbox probes receive no repository paths."""
    folder=ROOT/'Tests/TurtleGitCoreTests/Fixtures/Metafile'
    red=lambda x,y:{'point':[x,y],'min':[0.8,0,0],'max':[1,0.25,0.25]}
    green=lambda x,y:{'point':[x,y],'min':[0,0.8,0],'max':[0.25,1,0.25]}
    blue=lambda x,y:{'point':[x,y],'min':[0,0,0.8],'max':[0.25,0.25,1]}
    white=lambda x,y:{'point':[x,y],'min':[0.9,0.9,0.9],'max':[1,1,1]}
    cases=[
        {'name':'clip-vector.wmf','samples':[red(12,12),white(35,35)]},
        {'name':'classic-vector.emf','samples':[red(12,12),blue(58,12)]},
        {'name':'plus-bitmap-text.emf','samples':[red(12,12),green(28,12)],'svgContains':['Helvetica','TurtleGit','data:image/png;base64,']},
        {'name':'plus-gradient-blend.emf','samples':[red(16,24),blue(80,24),{'point':[48,24],'min':[0.35,0,0.35],'max':[1,0.25,1]}]},
        {'name':'plus-region-path.emf','samples':[red(12,12),white(28,28),blue(64,16)]},
        {'name':'plus-hatch-atlas.emf','samples':[],'hatchCell':[2,2,8,8],'deadline':True},
        {'name':'plus-raw-indexed4-negative.emf','samples':[red(12,12),green(28,12),blue(44,12)]},
        {'name':'plus-raw-texture-rgb565-positive.emf','samples':[red(12,12),green(28,12),blue(44,12),white(80,48)]},
        {'name':'unsupported-raw-palette-index.emf','samples':[],'refuse':True},
    ]
    originals={}
    for case in cases:
        path=folder/case['name'];data=path.read_bytes();digest=hashlib.sha256(data).hexdigest();originals[path]=digest
        case.update(bytes=base64.b64encode(data).decode(),sha256=digest,width=96,height=64)
    payload=base64.b64encode(json.dumps(cases,separators=(',',':')).encode()).decode()
    if len(payload)>192*1024:raise ValueError('Signed metafile payload exceeds bounded argv transport')
    return payload,originals

class MetafileChildren:
    """Observe/retire only the unique disposable clone's actual helper path."""
    def __init__(self,executable):
        self.executables={str(executable),str(executable.resolve(strict=True))};self.seen={};self.errors=[];self.stop=threading.Event()
        self.worker=threading.Thread(target=self.observe,daemon=True)
    def scan(self):
        result=subprocess.run(['/bin/ps','-axo','pid=,ppid=,pgid=,stat=,command='],capture_output=True,text=True,check=True,timeout=5)
        rows=[]
        for line in result.stdout.splitlines():
            fields=line.split(None,4)
            if len(fields)!=5:continue
            pid,parent,group=map(int,fields[:3]);rows.append((pid,parent,group,fields[3],fields[4]))
        return rows
    def owned(self,row):return any(row[4]==path or row[4].startswith(path+' ') for path in self.executables)
    def observe(self):
        try:
            while not self.stop.is_set():
                for row in self.scan():
                    if self.owned(row):self.seen[row[0]]=row
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
        if leftovers:raise RuntimeError('Owned signed metafile helper survived cleanup')
        if kind is None:
            if needed_cleanup:raise RuntimeError('Signed metafile helper outlived its parent request and required cleanup')
            if self.errors:raise RuntimeError('Cannot verify helper process ownership: '+'; '.join(self.errors))
            if not self.seen:raise RuntimeError('No actual packaged metafile helper execution was observed')
            if any(row[0]!=row[2] for row in self.seen.values()):raise RuntimeError('Metafile helper did not own its process group')
            if any(signal_receiver_group(row[2],0) for row in self.seen.values()):raise RuntimeError('Owned metafile helper process group did not drain')
            if any(row[0] in self.seen for row in self.scan()):raise RuntimeError('Owned metafile helper PID did not drain')
        self.result={'observed_helper_processes':len(self.seen),'owned_helper_pids':[row[0] for row in self.seen.values()],
                     'owned_helper_groups':[row[2] for row in self.seen.values()],'helper_processes_and_groups_drained':not leftovers}

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
    parser.add_argument('--identity',required=True,help='Installed Apple Development signing identity SHA-1.')
    parser.add_argument('--report',required=True,type=Path);args=parser.parse_args()
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
    if launch.get('MachServices')!={mach_service(args.team):True}:raise ValueError('Packaged service namespace differs')
    git=(app/'Contents/Helpers/Git/bin/git').resolve(strict=True)
    git_rights=entitlements(git)
    if signature(git)!=args.team or not all(git_rights.get(key) is True for key in ['com.apple.security.app-sandbox','com.apple.security.inherit']):
        raise ValueError('Packaged Git lacks same-team inherited sandbox signing')
    metafile_home=app/'Contents/Helpers/Metafile';metafile=(metafile_home/'metafile-convert').resolve(strict=True)
    if metafile.parent!=app/'Contents/MacOS' or not (metafile_home/'renderer.js').is_file():raise ValueError('Packaged Metafile runtime escaped signed MacOS layout or is incomplete')
    metafile_rights=entitlements(metafile)
    if signature(metafile)!=args.team or not all(metafile_rights.get(key) is True for key in ['com.apple.security.app-sandbox','com.apple.security.inherit']):
        raise ValueError('Packaged Metafile lacks same-team inherited sandbox signing')
    source=ROOT/'docs/qa/signed-finder-runtime-probe-2026-10-17.swift'
    products=app.parent
    record={'team':args.team,'group':group,'app':str(app),'actual_peer_signatures':3,'packaged_git_inherits_sandbox':True,'packaged_metafile_inherits_sandbox':True,'cases':[],'finder_activation':'not performed','service_registration':'not performed'}
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
        identifier=str(uuid.uuid4());snapshot=None
        def run(binary,mode,*extra):
            result=run_receiver([str(binary),mode,identifier,args.team,*extra],cwd=ROOT,env=environment,capture_output=True,text=True,timeout=90)
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            lines=[line for line in result.stdout.splitlines() if line.startswith('TURTLEGIT_SIGNED_QA ')]
            if len(lines)!=1:raise ValueError('Signed probe did not complete')
            value=json.loads(lines[0].split(' ',1)[1])
            if value.get('passed') is not True:raise ValueError('Signed probe reported failure: '+mode)
            record['cases'].append(value)
            return value
        try:
            snapshot=run(clones[0],'writer')['snapshot']
            record['packaged_lexilla_runs_from_sandbox']=True
            run(clones[0],'reader')
            run(clones[1],'denied',snapshot)
            payload,originals=metafile_request()
            with MetafileChildren(clones[0].parent.parent/'Helpers/Metafile/metafile-convert') as children:
                run(clones[0],'metafile',payload)
            record['metafile_children']=children.result;record['packaged_metafile_runs_from_sandbox']=True
            for path,digest in originals.items():
                if hashlib.sha256(path.read_bytes()).hexdigest()!=digest:raise ValueError('Signed probe changed original metafile fixture: '+path.name)
            record['metafile_fixture_files_unchanged']=True
        finally:
            run(clones[0],'cleanup')
    args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(record,indent=2)+'\n')
    print('PASS signed App Group runtime: independent sandbox processes, actual packaged Git and a denied nonmember. No installed Finder activation.')

if __name__=='__main__':main()
