#!/usr/bin/env python3
"""Grouped Send Mail source/native workflows; retained delivery uses private loopback only."""
import argparse,base64,json,os,subprocess,tempfile,time
from pathlib import Path
from native_receiver import build_receiver,run_receiver
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--git',type=Path,action='append');p.add_argument('--only',choices=['source','workflow'],action='append');p.add_argument('--captures',type=Path);args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-send-source-') as temporary:
    folder=Path(temporary);sources=[]
    for name in ['send-source-native-2026-10-17.swift','send-patch-dialog-native-2026-10-10.swift']:
        path=folder/name;path.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(path)
    main=folder/'SendSourceMain.swift';main.write_text('''import AppKit
@main struct SendSourceMain {
 @MainActor static func main()async {NSApp.setActivationPolicy(.prohibited);do {switch ProcessInfo.processInfo.environment["TURTLEGIT_SEND_SOURCE_CASE"] {
 case "source":try await SendSourceVerification.verify()
 case "workflow":try await SendPatchVerification.verify()
 default:fatalError("Unknown Send case")
 };await SendSourceVerification.cleanup();try SendSourceVerification.require(SendPatchWindowModel.activeLoads==0 && SendPatchWindowController.activeTargetReads==0,"Outstanding Send work");print("PASS: Send source family case completed")
 }catch{await SendSourceVerification.cleanup();fputs("FAIL Send source family: \\(error)\\n",stderr);exit(1)}}
}
''')
    receiver=build_receiver(root,sources+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0',GIT_AUTHOR_NAME='',GIT_AUTHOR_EMAIL='')
    for case in args.only or ['source','workflow']:
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=folder/(case+str(index));fixture.mkdir();active=env.copy();active.update(TURTLEGIT_SEND_SOURCE_CASE=case,TURTLEGIT_SEND_SOURCE_GIT=str(git.absolute()));active.pop('TURTLEGIT_SEND_SOURCE_CAPTURE',None)
            if args.captures and case=='source' and index==0:active['TURTLEGIT_SEND_SOURCE_CAPTURE']=str(args.captures.absolute())
            server=None
            try:
                argument=str(git.absolute())
                if case=='workflow':
                    server=subprocess.Popen(['/usr/bin/python3',str(root/'Tests/TurtleGitCoreTests/Fixtures/smtp_server.py'),str(fixture),'normal','180'])
                    ready=fixture/'ready.json';deadline=time.monotonic()+10
                    while not ready.exists() and server.poll() is None and time.monotonic()<deadline:time.sleep(.01)
                    argument=str(json.loads(ready.read_text())['port'])
                print('Checking Send '+case+' with '+str(git),flush=True)
                result=run_receiver([str(receiver),str(fixture),argument],cwd=root,env=active,capture_output=True,text=True,timeout=300)
                print(result.stdout,end='');print(result.stderr,end='');result.check_returncode()
                if 'PASS: Send source family case completed' not in result.stdout:raise SystemExit('Receiver exited before final assertions: '+case)
                if server:
                    assert server.wait(timeout=10)==0
                    state=json.loads((fixture/'result.json').read_text())
                    assert state['accepted']==1 and state['auth']==0 and state['data']==1
                    assert state['recipients']==['RCPT TO:<to@example.invalid>','RCPT TO:<cc@example.invalid>']
                    assert len(state['parts'])==3 and base64.b64decode(state['parts'][0]['payload'])==(fixture/'expected-body').read_bytes()
                    for part in state['parts'][1:]:assert part['filename']=='2.patch' and base64.b64decode(part['payload'])==(fixture/'expected-attachment').read_bytes()
            finally:
                if server:
                    if server.poll() is None:server.terminate()
                    server.wait(timeout=10);print('Owned SMTP server reaped: '+str(server.pid),flush=True)
