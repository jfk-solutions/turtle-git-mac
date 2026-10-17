#!/usr/bin/env python3
"""Native SVN certificate inspector/export and retained authentication family."""
import argparse,os,tempfile
from pathlib import Path
from native_receiver import build_receiver,run_receiver
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--captures',type=Path);a=p.parse_args()
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='TurtleGitCertificate-') as temporary:
    directory=Path(temporary)
    generated=root/'build/qa/certificate-inspector-sources';generated.mkdir(parents=True,exist_ok=True)
    legacy=generated/'SVNAuthenticationRegression.swift'
    legacy.write_text((root/'docs/qa/svn-authentication-native-2026-10-14.swift').read_text().replace('@main struct SVNAuthenticationVerification','struct SVNAuthenticationVerification'))
    helper=generated/'SVNPromptWindow.swift'
    helper.write_text('import TurtleGitCore\n'+(root/'Sources/TurtleGitGitAskpass/SVNPromptWindow.swift').read_text())
    receiver=build_receiver(root,[helper,legacy,root/'docs/qa/certificate-inspector-native-2026-10-17.swift'],directory)
    fixture=directory/'fixture';fixture.mkdir()
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),TURTLEGIT_CERTIFICATE_FIXTURE=str(root/'Tests/TurtleGitCoreTests/Fixtures/Certificates/server.der'))
    if a.captures:env['TURTLEGIT_CERTIFICATE_CAPTURES']=str(a.captures.absolute())
    result=run_receiver([str(receiver),str(fixture)],cwd=root,env=env,capture_output=True,text=True)
    print(result.stdout,end='',flush=True);print(result.stderr,end='',flush=True);result.check_returncode()
    if 'PASS: native certificate inspector' not in result.stdout:raise SystemExit('Missing completion marker')
