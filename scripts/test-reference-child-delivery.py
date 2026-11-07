#!/usr/bin/env python3
"""Grouped captured reference child delivery and connected navigation consumers."""
import argparse
import json
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = {
    'sheets': ('reference-child-delivery-native-2026-11-05.swift', 'ReferenceChildDeliveryVerification.verify()'),
    'browser': ('reference-browser-native-2026-10-09.swift', 'ReferenceBrowserVerification.verify()'),
    'rebase': ('rebase-references-native-2026-10-14.swift', 'RebaseReferencesVerification.verify()'),
    'switch': ('reference-switch-native-2026-10-09.swift', 'ReferenceSwitchVerification.verify()'),
    'compare': ('comparison-launch-native-2026-10-14.swift', 'ComparisonLaunchVerification.verify()'),
    'resolve': ('resolve-file-menu-native-2026-10-16.swift', 'ResolveFileMenuVerification.main()'),
    'submodule': ('history-submodule-inspection-native-2026-10-20.swift', 'HistorySubmoduleInspectionVerification.verify(caseName:"submodule",root:URL(fileURLWithPath:CommandLine.arguments[1]),git:URL(fileURLWithPath:CommandLine.arguments[2]),helper:URL(fileURLWithPath:CommandLine.arguments[5]))'),
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--only', choices=CASES, action='append')
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--helper', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-reference-child-delivery-') as temporary:
    folder = Path(temporary)
    sources = []
    for name, _ in CASES.values():
        source = folder / name
        source.write_text((root/'docs/qa'/name).read_text().replace('@main ', '', 1))
        sources.append(source)
    main = folder/'ReferenceChildDeliveryMain.swift'
    main.write_text(r'''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func turtleGitReferenceChildOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000))
  turtleGitReferenceChildOrder(place,relativeTo:number)
 }
}
@main struct ReferenceChildDeliveryMain {
 struct Failure:Error {let description:String}
 @MainActor static func main()async throws {
  NSApp.setActivationPolicy(.prohibited)
  let suite="TurtleGit.ChildDelivery.Geometry."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
  DialogGeometry.install(preferences:prefs)
  let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitReferenceChildOrder(_:relativeTo:)))!
  method_exchangeImplementations(original,hidden)
  defer{method_exchangeImplementations(original,hidden);DialogGeometry.install(preferences:.standard);prefs.removePersistentDomain(forName:suite)}
  var failure:Error?
  do {switch CommandLine.arguments[4] {
''' + ''.join('case "'+case+'":try await '+call+'\n' for case, (_, call) in CASES.items()) + r'''default:throw Failure(description:"Unknown child delivery case")
  }}catch{failure=error}
  for window in NSApp.windows {
   if let parent=window.sheetParent {parent.endSheet(window,returnCode:.abort)}
   window.orderOut(nil);window.close()
  }
  for _ in 0..<3000 {
   let idle = FinderFilesystemWorkflowRelease.activeRetirements==0 &&
    HistorySubmoduleInspectionVerification.drained() && ResolveWindowModel.activeOperations==0 &&
    RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0 &&
    RebaseWindowModel.activeReplayOperations==0 && RebaseWindowController.activeReferencePickers==0 &&
    SwitchWindowModel.activeReads==0 && SwitchProgressWindowModel.activeOperations==0 && SwitchWindowController.activeChildReleases==0 && FileListComparisonSession.activeOperations==0 &&
    NSApp.windows.allSatisfy{!$0.isVisible && $0.sheetParent==nil && $0.attachedSheet==nil}
   if idle {print("CLEANUP: reference child delivery drained");if let failure {throw failure};print("PASS: reference child delivery case completed");return}
   try await Task.sleep(nanoseconds:10_000_000)
  }
  throw Failure(description:"Child delivery owned cleanup did not drain; case error: "+String(describing:failure))
 }
}
''')
    receiver = build_receiver(root, sources+[main], folder)
    results=[]
    for case in args.only or CASES:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            private = folder/(case+str(index))
            fixture = private/'repository'
            fixture.mkdir(parents=True)
            for name in ['home', 'tmp', 'config']:
                (private/name).mkdir()
            env = {key:value for key,value in os.environ.items() if not key.startswith("GIT_")}
            env.update(HOME=str(private/'home'), CFFIXED_USER_HOME=str(private/'home'),
                       TMPDIR=str(private/'tmp')+'/', XDG_CONFIG_HOME=str(private/'config'),
                       GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                       DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'))
            env.pop('TURTLEGIT_REBASE_REF_GIT', None)
            print('Checking reference child delivery '+case+' with '+str(git), flush=True)
            command = [str(receiver), str(fixture), str(git.absolute()),
                       str(root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac'), case,
                       str((args.helper or root/'build/libgit2-runtime/LibGit2/bin/turtlegit-libgit2').absolute())]
            result = run_receiver(command, cwd=root, env=env, capture_output=True, text=True)
            print(result.stdout, end='')
            print(result.stderr, end='')
            # Continue independent, private cases only after the native owner
            # confirms its windows, sheets and workers drained. run_receiver
            # has also reaped this exact process group before returning.
            if 'CLEANUP: reference child delivery drained' not in result.stdout:
                raise SystemExit('Unsafe/unfinished native cleanup; refusing later cases: '+case+'; exit '+str(result.returncode))
            passed=result.returncode==0 and 'PASS: reference child delivery case completed' in result.stdout
            results.append({'case':case,'git':str(git),'passed':passed,'exit_code':result.returncode})
            print('RESULT '+json.dumps(results[-1],sort_keys=True),flush=True)
    failed=[entry for entry in results if not entry['passed']]
    if failed:
        raise SystemExit('Grouped child delivery failed: '+json.dumps(failed,sort_keys=True))
