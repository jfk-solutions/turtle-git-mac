#!/usr/bin/env python3
"""Private cached native First Start SSH setup, save order and ownership."""
import argparse
import json
import os
import plistlib
import shutil
import uuid
import signal
import subprocess
import time
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

def retire_owned_helpers(context, approved):
    """Git creates its own group; require its image AND private request resource."""
    def owned():
        listing = subprocess.run(['/usr/sbin/lsof','-t','+D',str(context)],capture_output=True,text=True,timeout=10)
        if listing.returncode not in (0,1):raise RuntimeError('Cannot inspect private First Start SSH helper ownership')
        result = []
        for value in set(listing.stdout.split()):
            pid = int(value)
            images = subprocess.run(['/usr/sbin/lsof','-a','-p',str(pid),'-d','txt','-Fn'],capture_output=True,text=True,timeout=5)
            actual = {str(Path(line[1:]).resolve()) for line in images.stdout.splitlines() if line.startswith('n')}
            if actual.intersection(approved):result.append(pid)
        return result
    remaining = owned();needed = bool(remaining)
    for action in [signal.SIGTERM,signal.SIGKILL]:
        for pid in remaining:
            if pid not in owned():continue
            try:
                os.killpg(pid,action) if os.getpgid(pid) == pid else os.kill(pid,action)
            except ProcessLookupError:pass
        deadline = time.monotonic()+3
        while time.monotonic() < deadline:
            remaining = owned()
            if not remaining:break
            time.sleep(.03)
        if not remaining:return needed
    raise RuntimeError('Owned First Start SSH helper survived cleanup: '+str(remaining))

def private_application_receiver(receiver, context):
    """Give real Foundation app-scoped bookmarks an explicit QA app identity.

    This is an ad-hoc, nonshipping UI host, not a sandbox/Powerbox acceptance
    claim. Never mutate the cached binary, register with Launch Services, add a
    fake Team identifier, grant sandbox exceptions or change keychain state.
    """
    identifier = 'org.turtlegit.qa.firststartssh.' + uuid.uuid4().hex
    bundle = context/'FirstStartSSH-QA.app'
    contents = bundle/'Contents'; macos = contents/'MacOS'
    macos.mkdir(parents=True, mode=0o700)
    executable = macos/'FirstStartSSHReceiver'
    shutil.copy2(receiver, executable); executable.chmod(0o700)
    info = dict(CFBundleIdentifier=identifier, CFBundleExecutable=executable.name,
                CFBundleName='TurtleGit First Start SSH QA', CFBundlePackageType='APPL',
                CFBundleVersion='1', CFBundleShortVersionString='1', LSUIElement=True,
                LSMinimumSystemVersion='13.0')
    (contents/'Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', identifier,
                    '--timestamp=none', str(bundle)], check=True, capture_output=True, text=True, timeout=30)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--verbose=2', str(bundle)],
                   check=True, capture_output=True, text=True, timeout=30)
    signature = subprocess.run(['/usr/bin/codesign', '--display', '--verbose=4', str(executable)],
                               check=True, capture_output=True, text=True, timeout=10)
    print('Private First Start SSH application identity: '+identifier+'; ad-hoc nonshipping host; no sandbox acceptance claim', flush=True)
    print(signature.stdout+signature.stderr, end='', flush=True)
    return executable

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--captures', type=Path)
parser.add_argument('--only', choices=['choices', 'picker', 'lifetime'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
cache = root/'build/qa/first-start-ssh-native-sources'
cache.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [root/'docs/qa/first-start-ssh-native-2026-10-24.swift'], cache)
results = []
for case in args.only or ['choices', 'picker', 'lifetime']:
    for git in args.git or [Path('/usr/bin/git'), root/'build/git-runtime/Git/bin/git']:
        with tempfile.TemporaryDirectory(prefix='turtlegit-first-start-ssh-') as temporary:
            # Canonicalize the private fixture root before constructing argv,
            # homes and injected selections; do not transform user-picked URLs.
            # This removes the /var -> /private/var fixture alias consistently.
            context = Path(temporary).resolve()
            env = {k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
            for name, key in [('home','HOME'), ('preferences','CFFIXED_USER_HOME'), ('xdg','XDG_CONFIG_HOME'), ('temporary','TMPDIR')]:
                folder = context/name; folder.mkdir(mode=0o700)
                env[key] = str(folder)+('/' if key == 'TMPDIR' else '')
            fixture = context/'fixture'; fixture.mkdir(mode=0o700)
            env.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
            if args.captures and case == 'choices':
                args.captures.mkdir(parents=True, exist_ok=True)
                env['TURTLEGIT_FIRST_START_SSH_CAPTURE'] = str(args.captures.absolute())
            else:
                env.pop('TURTLEGIT_FIRST_START_SSH_CAPTURE', None)
            print('Checking First Start SSH '+case+' with '+str(git), flush=True)
            approved = {str(git.resolve())}
            resolved = subprocess.run(['/usr/bin/xcrun','--find','git'], capture_output=True, text=True)
            if resolved.returncode == 0: approved.add(str(Path(resolved.stdout.strip()).resolve()))
            passed = False
            try:
                application_receiver = private_application_receiver(receiver, context)
                result = run_receiver([str(application_receiver), str(fixture), str(git.absolute()), case], cwd=root, env=env, capture_output=True, text=True,
                                      timeout_sample=root/('build/qa/first-start-ssh-'+case+'.sample.txt'))
                print(result.stdout, end=''); print(result.stderr, end='')
                passed = result.returncode == 0 and ('PASS: First Start SSH '+case) in result.stdout
                results.append(dict(case=case, git=str(git.absolute()), returncode=result.returncode, passed=passed))
                (root/'build/qa/first-start-ssh-native-results.json').write_text(json.dumps(results, indent=2)+'\n')
                result.check_returncode()
                if not passed: raise RuntimeError('Receiver exited before final assertions: '+case)
            finally:
                if retire_owned_helpers(context, approved) and passed:
                    results[-1].update(passed=False, helper_cleanup_needed=True)
                    (root/'build/qa/first-start-ssh-native-results.json').write_text(json.dumps(results, indent=2)+'\n')
                    raise RuntimeError('Completed First Start SSH request left an owned Git helper running')
