#!/usr/bin/env python3
"""Grouped Word/LibreOffice routing and automation contracts; never launch Office."""
import argparse
import json
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = {
    'word': ('word-comparison-native-2026-10-16.swift', 'WordComparisonNativeVerification.verify()'),
    'merge': ('word-merge-native-2026-10-16.swift', 'WordMergeNativeVerification.verify()'),
    'libreoffice': ('libreoffice-comparison-native-2026-10-16.swift', 'LibreOfficeComparisonNativeVerification.verify()'),
    'contract': ('word-automation-contract-native-2026-10-20.swift', 'WordAutomationContractNativeVerification.verify(root:root,git:git)'),
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
parser.add_argument('--check-word-terminology', action='store_true', help='Compile fixed handlers against an installed Word dictionary; execute no Office commands.')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
sources = root/'build/qa/word-office-family-sources'
sources.mkdir(parents=True, exist_ok=True)
base = {key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
base.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
if args.check_word_terminology:
    base['TURTLEGIT_CHECK_WORD_TERMINOLOGY'] = '1'
with tempfile.TemporaryDirectory(prefix='turtlegit-word-office-') as temporary:
    for case in args.only or CASES:
        filename, call = CASES[case]
        fixture = sources/(case+'.swift')
        # The wrapper owns hiding, cleanup and drain for each fixture, including
        # failure paths; existing assertions and source locations are retained.
        original = root/'docs/qa'/filename
        fixture.write_text('#sourceLocation(file: '+json.dumps(str(original))+', line: 1)\n'+original.read_text().replace('@main struct ', 'struct '))
        main = sources/(case+'Main.swift')
        main.write_text(r'''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func turtleGitOfficeOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-16000,y:-16000));turtleGitOfficeOrder(place,relativeTo:number)
 }
}
@main struct WordOfficeFamilyMain {
 @MainActor static func closeWindows() {
  for window in NSApp.windows {
   if let sheet=window.attachedSheet {window.endSheet(sheet,returnCode:.abort);sheet.close()}
   if let parent=window.sheetParent {parent.endSheet(window,returnCode:.abort)}
   window.close()
  }
 }
 @MainActor static func drain()async throws {
  for _ in 0..<1500 {
   if DiffToolApplication.activeRequests==0 && MergeToolApplication.activeRequests==0 && NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}) {return}
   try await Task.sleep(nanoseconds:10_000_000)
  }
  throw NSError(domain:"Office-owned work or windows survived cleanup",code:1)
 }
 @MainActor static func main()async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let suite="TurtleGit.OfficeFamily.Geometry."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
  DialogGeometry.install(preferences:prefs)
  defer {DialogGeometry.install(preferences:.standard);prefs.removePersistentDomain(forName:suite)}
  let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitOfficeOrder(_:relativeTo:)))!
  method_exchangeImplementations(normal,hidden);defer {method_exchangeImplementations(normal,hidden)}
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
  do {
   try await '''+call+r'''
  } catch {
   let failure=error;DiffToolApplication.discardAll();MergeToolApplication.discardAll();closeWindows()
   do {try await drain()}catch {throw NSError(domain:"\(failure); cleanup: \(error)",code:1)}
   throw failure
  }
  DiffToolApplication.discardAll();MergeToolApplication.discardAll();closeWindows();try await drain()
  print("PASS: grouped Office family completed")
 }
}
''')
        receiver = build_receiver(root, [fixture, main], sources)
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            directory = Path(temporary)/(case+str(index));directory.mkdir()
            # Transport fixtures only: no claim of live DOCX converter acceptance.
            (directory/'old " 雪.docx').write_bytes(b'old captured Word bytes\x00\xff')
            (directory/'new.docx').write_bytes(b'new captured Word bytes\x00\xfe')
            home=directory/'home';home.mkdir(mode=0o700)
            private_tmp=directory/'tmp';private_tmp.mkdir(mode=0o700)
            config=directory/'global.config';config.write_text('')
            env=dict(base,GIT_CONFIG_GLOBAL=str(config),XDG_CONFIG_HOME=str(directory/'xdg'),CFFIXED_USER_HOME=str(home),TMPDIR=str(private_tmp)+'/')
            print('Checking Office '+case+' with '+str(git),flush=True)
            result=run_receiver([str(receiver),str(directory),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True,timeout_sample=directory/'timeout.sample.txt')
            print(result.stdout,end='',flush=True);print(result.stderr,end='',flush=True);result.check_returncode()
            if 'PASS: grouped Office family completed' not in result.stdout:
                raise SystemExit('Office receiver exited before cleanup completion: '+case)
