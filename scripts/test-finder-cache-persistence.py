#!/usr/bin/env python3
"""Connected CacheSave settings, live publisher leases and service restart workflows."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

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
    folder=Path(temporary)
    base={key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
    base.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0')
    for case in args.only or ['settings','lifecycle','roots']:
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            directory=folder/(case+str(index));directory.mkdir()
            config=directory/'global.config';config.write_text('')
            private_tmp=directory/'temporary';private_tmp.mkdir(mode=0o700)
            env=dict(base,GIT_CONFIG_GLOBAL=str(config),XDG_CONFIG_HOME=str(directory/'xdg'),TMPDIR=str(private_tmp)+'/')
            print('Checking Finder cache '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(directory),str(git.absolute()),case],cwd=root,env=env,capture_output=True,text=True,timeout_sample=directory/'timeout.sample.txt')
            print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
            if 'PASS: Finder cache persistence workflow completed: '+case not in result.stdout:raise SystemExit('Finder cache receiver exited before completion: '+case)
