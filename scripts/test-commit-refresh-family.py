#!/usr/bin/env python3
"""Grouped complete Commit reads, staging, editor metadata, templates, providers and native list restoration."""
import argparse,ast,json,os,re,signal,subprocess,tempfile,time
from pathlib import Path
from native_receiver import build_receiver,run_receiver
cases=[('snapshot','commit-refresh-snapshot-native-2026-10-17.swift','PASS Commit refresh snapshot:'),('staging','commit-staging-list-native-2026-10-16.swift','PASS: Commit incremental staging'),('metadata','commit-metadata-native-2026-10-09.swift','PASS: actual hidden Commit metadata'),('preferences','commit-preferences-native-2026-10-13.swift','Commit templates:'),('provider','native-issue-provider-native-2026-10-14.swift','PASS native issue providers:'),('position','file-list-refresh-native-2026-10-16.swift','PASS file-list refresh:')]
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--git',type=Path,action='append');parser.add_argument('--only',choices=[case[0] for case in cases],action='append');args=parser.parse_args();root=Path(__file__).resolve().parent.parent
cleanup_tree=ast.parse((root/'scripts/test-log-file-drags.py').read_text())
cleanup=next(item for item in cleanup_tree.body if isinstance(item,ast.FunctionDef) and item.name=='retire_owned_helpers')
namespace=dict(os=os,signal=signal,time=time,subprocess=subprocess,Path=Path)
exec(compile(ast.Module(body=[cleanup],type_ignores=[]),'<owned Commit refresh helper cleanup>','exec'),namespace)
retire_owned_helpers=namespace['retire_owned_helpers']
results=[]
generated=root/'build/qa/commit-refresh-family-sources';generated.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='tg-commit-refresh-') as temporary:
    folder=Path(temporary)
    for name,source,marker in cases:
        if args.only and name not in args.only:continue
        build=folder/name;build.mkdir()
        text=(root/'docs/qa'/source).read_text()
        entry=re.search(r'@main\s+(?:struct|enum|class)\s+(\w+)',text)
        if not entry:raise RuntimeError('Missing Commit fixture entry point: '+source)
        sources=generated/name;sources.mkdir(parents=True,exist_ok=True)
        # Stable source paths retain receiver-cache identity across invocations;
        # the original directive also keeps #filePath/diagnostics at the fixture.
        fixture_source=sources/source
        fixture_source.write_text('#sourceLocation(file: '+json.dumps(str(root/'docs/qa'/source))+', line: 1)\n'+text.replace('@main ','',1))
        main=sources/'CommitRefreshMain.swift'
        main.write_text('''import AppKit
import ObjectiveC
private extension NSWindow {
 @objc func commitRefreshOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
  alphaValue=0;setFrameOrigin(.init(x:-30000,y:-30000));commitRefreshOrder(mode,relativeTo:number)
 }
 @objc func commitRefreshConstrain(_ frame:NSRect,to screen:NSScreen?)->NSRect {frame}
}
@main struct CommitRefreshMain {
 @MainActor static func main() async throws {
  NSApp.setActivationPolicy(.prohibited)
  let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
  let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.commitRefreshOrder(_:relativeTo:)))!
  let constrain=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:)))!
  let offscreen=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.commitRefreshConstrain(_:to:)))!
  method_exchangeImplementations(order,hidden);method_exchangeImplementations(constrain,offscreen)
  defer {method_exchangeImplementations(order,hidden);method_exchangeImplementations(constrain,offscreen)}
  var failure:Error?
  do {try await '''+entry.group(1)+'''.main()} catch {failure=error}
  for window in NSApp.windows {if let parent=window.sheetParent {parent.endSheet(window,returnCode:.abort)};window.close()}
  var drained=false
  for _ in 0..<3000 {
   if CommitWindowModel.activeReloads==0,CommitWindowModel.activeFileOperations==0,
      CommitWindowModel.activeMetadataOperations==0,CommitWindowModel.activePreferenceOperations==0,
      CommitWindowModel.activeFileDrops==0,CommitWindowModel.activeIssueProviderOperations==0,
      StatusWindowModel.activeOperations==0,RevertWindowModel.activeOperations==0,
      NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}) {drained=true;break}
   try await Task.sleep(nanoseconds:10_000_000)
  }
  guard drained else {throw NSError(domain:"TurtleGit.CommitRefreshFixture",code:1,userInfo:[NSLocalizedDescriptionKey:"Owned Commit refresh windows/readers did not drain"])}
  if let failure {throw failure}
  print("PASS: Commit refresh owned case completed")
 }
}
''')
        receiver=build_receiver(root,[fixture_source,main],build)
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            context=build/str(index);context.mkdir()
            for child in ['fixture','preferences','temporary','xdg','home']:(context/child).mkdir(mode=0o700)
            config=context/'global.config';config.write_text('')
            env={key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
            env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=str(config),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',CFFIXED_USER_HOME=str(context/'preferences'),HOME=str(context/'home'),TMPDIR=str(context/'temporary')+'/',XDG_CONFIG_HOME=str(context/'xdg'))
            git=git.absolute();passed=False
            print('Checking Commit refresh '+name+' with '+str(git),flush=True)
            try:
                result=run_receiver([str(receiver),str(context/'fixture'),str(git)],cwd=root,env=env,capture_output=True,text=True,timeout=300,timeout_sample=context/'timeout.sample.txt')
                (context/'stdout.log').write_text(result.stdout);(context/'stderr.log').write_text(result.stderr)
                print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
                passed=marker in result.stdout and 'PASS: Commit refresh owned case completed' in result.stdout
                if not passed:raise RuntimeError('Receiver did not finish assertions/cleanup: '+name)
                results.append(dict(case=name,git=str(git),exit_code=0,passed=True))
                (root/'build/qa/commit-refresh-family-results.json').write_text(json.dumps(results,indent=2)+'\n')
            except BaseException:
                import shutil
                failures=root/'build/qa/native-commit-refresh-failures';failures.mkdir(parents=True,exist_ok=True)
                evidence=Path(tempfile.mkdtemp(prefix=name+'-',dir=failures));shutil.copytree(context,evidence,dirs_exist_ok=True,symlinks=True)
                print('Retained private Commit refresh evidence: '+str(evidence),flush=True)
                raise
            finally:
                approved={str(git.resolve()),str(Path('/bin/sh').resolve()),str(Path('/bin/sleep').resolve())}
                selected=subprocess.run(['/usr/bin/xcrun','--find','git'],capture_output=True,text=True,timeout=10)
                if selected.returncode==0:approved.add(str(Path(selected.stdout.strip()).resolve()))
                needed=retire_owned_helpers(context,approved)
                if passed and needed:raise RuntimeError('Successful Commit refresh receiver left owned helpers running')
