#!/usr/bin/env python3
"""Connected CacheSave settings, live publisher leases and service restart workflows."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid
from native_receiver import build_receiver, run_receiver


def private_application_receiver(receiver, context):
    """Retain actual Foundation app-scoped bookmarks in an identified QA host.

    Match the existing First Start SSH receiver contract: copy, never mutate the
    compilation cache; no Launch Services registration, Team identity, sandbox
    entitlement, keychain change or shipping permission claim.
    """
    identifier='org.turtlegit.qa.cachepersistence.'+uuid.uuid4().hex
    bundle=context/'CachePersistence-QA.app'
    contents=bundle/'Contents';macos=contents/'MacOS'
    macos.mkdir(parents=True,mode=0o700)
    executable=macos/'CachePersistenceReceiver'
    shutil.copy2(receiver,executable);executable.chmod(0o700)
    (contents/'Info.plist').write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier=identifier,CFBundleExecutable=executable.name,
        CFBundleName='TurtleGit Cache Persistence QA',CFBundlePackageType='APPL',
        CFBundleVersion='1',CFBundleShortVersionString='1',LSUIElement=True,
        LSMinimumSystemVersion='13.0')))
    subprocess.run(['/usr/bin/codesign','--force','--sign','-','--identifier',identifier,
                    '--timestamp=none',str(bundle)],check=True,capture_output=True,text=True,timeout=30)
    subprocess.run(['/usr/bin/codesign','--verify','--strict','--verbose=2',str(bundle)],
                   check=True,capture_output=True,text=True,timeout=30)
    print('Private cache-persistence application identity: '+identifier+'; ad-hoc nonshipping host; no sandbox acceptance claim',flush=True)
    return executable


parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git',type=Path,action='append')
parser.add_argument('--only',choices=['settings','lifecycle','roots'],action='append')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
generated=root/'build/qa/finder-cache-persistence-sources'
generated.mkdir(parents=True,exist_ok=True)
fixtures=[root/'FinderSync/FinderSync.swift']
for name in ['finder-publication-native-2026-10-13.swift','finder-publication-worker-native-2026-10-13.swift','finder-root-identity-native-2026-10-18.swift','finder-cache-persistence-native-2026-10-19.swift']:
    path=generated/name
    contents=(root/'docs/qa'/name).read_text().replace('@main ','',1)
    if not path.is_file() or path.read_text()!=contents:path.write_text(contents)
    fixtures.append(path)
main=generated/'FinderCachePersistenceMain.swift'
contents='''import AppKit
import ObjectiveC
private extension NSWindow {
    @objc func turtleGitCachePersistenceOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000))
        turtleGitCachePersistenceOrder(place,relativeTo:number)
    }
}
@main struct FinderCachePersistenceMain {
    @MainActor static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
        let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitCachePersistenceOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden)
        defer {method_exchangeImplementations(original,hidden)}
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),mode=CommandLine.arguments[3]
        if mode=="worker" {try await FinderCachePersistenceVerification.worker(folder);return}
        if mode=="root-worker" {try await FinderRootIdentityVerification.worker();return}
        if mode=="finder-publication-worker" {await FinderPublicationWorker.main();return}
        do {
            switch mode {
            case "settings":try await FinderCachePersistenceVerification.settings(folder,git)
            case "lifecycle":try await FinderCachePersistenceVerification.lifecycle(folder,git)
            case "roots":try await FinderRootIdentityVerification.verify();try await FinderPublicationVerification.verify()
            default:fatalError("Unknown Finder cache case")
            }
        } catch {await FinderCachePersistenceVerification.cleanup();throw error}
        await FinderCachePersistenceVerification.cleanup()
        print("PASS: Finder cache persistence workflow completed: "+mode)
    }
}
'''
if not main.is_file() or main.read_text()!=contents:main.write_text(contents)
receiver=build_receiver(root,fixtures+[main],generated)
with tempfile.TemporaryDirectory(prefix='turtlegit-cache-persistence-') as temporary:
    # Preserve this fixture's original /var spelling. Its exact snapshot keys
    # must agree with Foundation/Git standardized repository paths on macOS;
    # resolving only the runner root introduces a separate /private/var alias.
    folder=Path(temporary)
    base={key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
    base.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case in args.only or ['settings','lifecycle','roots']:
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            directory=folder/(case+str(index));directory.mkdir()
            config=directory/'global.config';config.write_text('')
            private_tmp=directory/'temporary';private_tmp.mkdir(mode=0o700)
            for name in ['home','preferences','xdg']:(directory/name).mkdir(mode=0o700)
            env=dict(base,GIT_CONFIG_GLOBAL=str(config),HOME=str(directory/'home'),CFFIXED_USER_HOME=str(directory/'preferences'),XDG_CONFIG_HOME=str(directory/'xdg'),TMPDIR=str(private_tmp)+'/')
            print('Checking Finder cache '+case+' with '+str(git),flush=True)
            result=None
            try:
                application_receiver=private_application_receiver(receiver,directory)
                result=run_receiver([str(application_receiver),str(directory),str(git.absolute()),case],cwd=root,env=env,capture_output=True,text=True,timeout_sample=directory/'timeout.sample.txt')
                print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
                if 'PASS: Finder cache persistence workflow completed: '+case not in result.stdout:raise SystemExit('Finder cache receiver exited before completion: '+case)
            except BaseException as error:
                # run_receiver has already stopped/reaped its owned process
                # group. Retain only this private case locally before the
                # TemporaryDirectory removes it; never upload grant archives.
                failures=root/'build/qa/finder-cache-persistence-failures'
                failures.mkdir(parents=True,exist_ok=True)
                retained=Path(tempfile.mkdtemp(prefix=case+'-'+str(index)+'-',dir=failures))
                shutil.copytree(directory,retained,dirs_exist_ok=True,symlinks=True)
                for name in ['stdout','stderr']:
                    output=getattr(result,name,None) if result is not None else getattr(error,name,None)
                    if output is None and name=='stdout':output=getattr(error,'output',None)
                    if isinstance(output,bytes):output=output.decode('utf-8',errors='replace')
                    (retained/('receiver.'+name+'.log')).write_text(output or '')
                (retained/'failure.txt').write_text(str(error)+'\n')
                print('Private Finder cache failure context retained locally: '+str(retained),flush=True)
                raise
