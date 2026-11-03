#!/usr/bin/env python3
"""Grouped source Switch form, retained full pickers and real checkout/progress."""
import argparse,os,signal,subprocess,tempfile,time
from pathlib import Path
from native_receiver import build_receiver,run_receiver

def retire_owned_helpers(fixture, approved_images):
    """Reap only exact Git images or this fixture's authored slow-switch job.

    CancellableGitProcess starts separate process groups, so receiver teardown
    alone cannot retire a helper left behind by a crashed assertion.
    """
    # Preserve argv spelling as passed to the receiver as well as macOS's
    # canonical /private/var alias; both name this exact authored wrapper.
    wrappers={str(fixture.absolute()/'slow-git'),str(fixture.resolve()/'slow-git')}
    fixture=fixture.resolve()
    shell=str(Path('/bin/sh').resolve())
    sleeper=str(Path('/bin/sleep').resolve())
    def owned():
        listing=subprocess.run(['/usr/sbin/lsof','-t','+D',str(fixture)],capture_output=True,text=True,timeout=10)
        if listing.returncode not in (0,1):raise RuntimeError('Cannot inspect private Switch helper ownership')
        try:
            recorded=[int(value) for value in (fixture/'slow-git.started').read_text().split()]
        except (FileNotFoundError,ValueError):recorded=[]
        result=[]
        for value in set(listing.stdout.split()):
            pid=int(value)
            executable=subprocess.run(['/usr/sbin/lsof','-a','-p',str(pid),'-d','txt','-Fn'],capture_output=True,text=True,timeout=5)
            images={str(Path(line[1:]).resolve()) for line in executable.stdout.splitlines() if line.startswith('n')}
            if images.intersection(approved_images):result.append(pid);continue
            command=subprocess.run(['/bin/ps','-p',str(pid),'-o','command='],capture_output=True,text=True,timeout=5).stdout.strip()
            if shell in images and any(command=='/bin/sh '+wrapper or command.startswith('/bin/sh '+wrapper+' ') for wrapper in wrappers):
                result.append(pid)
            elif sleeper in images and command=='/bin/sleep 30' and len(recorded)==2 and pid==recorded[1]:
                try:
                    if os.getpgid(pid)==recorded[0]:result.append(pid)
                except ProcessLookupError:pass
        return result
    remaining=owned();needed=bool(remaining)
    for number in (signal.SIGTERM,signal.SIGKILL):
        for pid in remaining:
            if pid not in owned():continue
            try:
                group=os.getpgid(pid)
                os.killpg(group,number) if group==pid else os.kill(pid,number)
            except ProcessLookupError:pass
        deadline=time.monotonic()+3
        while time.monotonic()<deadline:
            remaining=owned()
            if not remaining:return needed
            time.sleep(.03)
    raise RuntimeError('Verified private Switch helper survived cleanup: '+str(remaining))

cases={'source':('switch-source-native-2026-10-17.swift','SwitchSourceVerification','verify'),'pickers':('switch-pickers-native-2026-10-09.swift','SwitchPickerVerification','verify'),'progress':('switch-progress-native-2026-10-08.swift','SwitchProgressVerification','main')}
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--git',type=Path,action='append');p.add_argument('--only',choices=cases,action='append');p.add_argument('--captures',type=Path);args=p.parse_args();root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-switch-source-') as temporary:
    folder=Path(temporary);sources=[]
    for name,_,_ in cases.values():
        path=folder/name;path.write_text((root/'docs/qa'/name).read_text().replace('@main ', '',1));sources.append(path)
    main=folder/'SwitchSourceMain.swift';main.write_text('import AppKit\n@main struct SwitchSourceMain { @MainActor static func main() async throws { NSApp.setActivationPolicy(.prohibited); switch CommandLine.arguments[3] {\n'+''.join('case "'+case+'": try await '+kind+'.'+entry+'()\n' for case,(_,kind,entry) in cases.items())+'default: fatalError("Unknown Switch case")\n}; print("PASS: Switch source family case completed") } }\n')
    receiver=build_receiver(root,sources+[main],folder)
    env=os.environ.copy();env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_COUNT='0');env.pop('TURTLEGIT_SWITCH_SOURCE_CAPTURE',None)
    for case in args.only or cases:
        for index,git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture=folder/(case+str(index));fixture.mkdir();active=env.copy()
            if args.captures and case=='source' and index==0:active['TURTLEGIT_SWITCH_SOURCE_CAPTURE']=str(args.captures.absolute())
            print('Checking Switch '+case+' with '+str(git),flush=True)
            approved={str(git.resolve())}
            resolved=subprocess.run(['/usr/bin/xcrun','--find','git'],capture_output=True,text=True,timeout=10)
            if resolved.returncode==0:approved.add(str(Path(resolved.stdout.strip()).resolve()))
            passed=False
            try:
                result=run_receiver([str(receiver),str(fixture),str(git.absolute()),case],cwd=root,env=active,capture_output=True,text=True)
                print(result.stdout,end='');print(result.stderr,end='')
                passed=result.returncode==0 and 'PASS: Switch source family case completed' in result.stdout
                result.check_returncode()
                if not passed:raise SystemExit('Receiver exited before final assertions: '+case)
            finally:
                if retire_owned_helpers(fixture,approved) and passed:
                    raise RuntimeError('Completed Switch '+case+' left an owned Git/helper process running')
