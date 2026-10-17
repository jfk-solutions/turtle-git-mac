#!/usr/bin/env python3
"""Exercise actual sandboxed App Group sharing and packaged Git with an installed signing identity.
Clones are run directly, with unique QA bundle IDs; no launch/Finder service is registered.
"""
import argparse,json,os,platform,plistlib,re,subprocess,tempfile,uuid
from pathlib import Path
from finder_group_identity import app_group,mach_service
from native_receiver import run_receiver
ROOT=Path(__file__).resolve().parent.parent

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
    source=ROOT/'docs/qa/signed-finder-runtime-probe-2026-10-17.swift'
    products=app.parent
    record={'team':args.team,'group':group,'app':str(app),'actual_peer_signatures':3,'packaged_git_inherits_sandbox':True,'cases':[],'finder_activation':'not performed','service_registration':'not performed'}
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
            value=json.loads(lines[0].split(' ',1)[1]);record['cases'].append({'mode':mode,'passed':value.get('passed') is True})
            return value
        try:
            snapshot=run(clones[0],'writer')['snapshot']
            record['packaged_lexilla_runs_from_sandbox']=True
            run(clones[0],'reader')
            run(clones[1],'denied',snapshot)
        finally:
            run(clones[0],'cleanup')
    args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(record,indent=2)+'\n')
    print('PASS signed App Group runtime: independent sandbox processes, actual packaged Git and a denied nonmember. No installed Finder activation.')

if __name__=='__main__':main()
