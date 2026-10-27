#!/usr/bin/env python3
"""Grouped actual-renderer/native image workflows with reusable linked receivers."""
import argparse
import os
import json
import shutil
import signal
import subprocess
import time
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

def retire_owned_helpers(context, approved):
    """Only approved helper executables holding this private request are owned."""
    def owned():
        holders = subprocess.run(['/usr/sbin/lsof', '-t', '+D', str(context)],
                                 capture_output=True, text=True, timeout=10)
        if holders.returncode not in (0, 1):
            raise RuntimeError('Could not inspect private metafile request ownership')
        result = []
        for value in set(holders.stdout.split()):
            pid = int(value)
            images = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'txt', '-Fn'],
                                    capture_output=True, text=True, timeout=5)
            actual = {str(Path(line[1:]).resolve()) for line in images.stdout.splitlines() if line.startswith('n')}
            if actual.intersection(approved):
                result.append(pid)
        return result

    remaining = owned()
    cleanup_needed = bool(remaining)
    for action in [signal.SIGTERM, signal.SIGKILL]:
        for pid in remaining:
            if pid not in owned():
                continue
            try:
                group = os.getpgid(pid)
                os.killpg(group, action) if group == pid else os.kill(pid, action)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            remaining = owned()
            if not remaining:
                break
            time.sleep(.03)
        if not remaining:
            break
    if remaining:
        raise RuntimeError('Owned approved metafile helper survived cleanup: ' + str(remaining))
    return cleanup_needed


CASES = {'image-effects': ('metafile-image-effects-native-2026-10-27.swift', 'MetafileImageEffectsVerification')}

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
parser.add_argument('--capture-dir', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
# Stable source paths preserve #sourceLocation and hence native_receiver's full
# content/toolchain/framework cache. Repositories and preferences remain private.
generated = root/'build/qa/metafile-native-sources'
generated.mkdir(parents=True, exist_ok=True)
fixtures = []
for filename in dict.fromkeys(filename for filename, _ in CASES.values()):
    path = generated/filename
    contents = (root/'docs/qa'/filename).read_text().replace('@main ', '', 1)
    if not path.is_file() or path.read_text() != contents:
        path.write_text(contents)
    fixtures.append(path)
dispatch = 'case "image-effects": try await MetafileImageEffectsVerification.verify()'
main = generated/'MetafileWorkflowMain.swift'
main_contents = '''import AppKit
import ObjectiveC
private extension NSWindow {
    @objc func turtleGitMetafileOrder(_ place: NSWindow.OrderingMode, relativeTo number: Int) {
        alphaValue = 0;setFrameOrigin(.init(x:-12000,y:-12000))
        turtleGitMetafileOrder(place, relativeTo: number)
    }
}
@main struct MetafileWorkflowMain {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)))!
        let hidden = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.turtleGitMetafileOrder(_:relativeTo:)))!
        method_exchangeImplementations(original, hidden)
        defer { method_exchangeImplementations(original, hidden) }
        // Test-owned invocations must not read modifiers from the user's desktop.
        try await ComparisonToolInvocation.$alternate.withValue(false) {
        switch ProcessInfo.processInfo.environment["TURTLEGIT_METAFILE_CASE"]! {
''' + dispatch + '''
        default: fatalError("Unknown metafile workflow")
        }
        }
        print("PASS: metafile workflow completed")
    }
}
'''
if not main.is_file() or main.read_text() != main_contents:
    main.write_text(main_contents)
receiver = build_receiver(root, fixtures+[main], generated)
results=[]
with tempfile.TemporaryDirectory(prefix='turtlegit-metafile-workflows-') as temporary:
    folder = Path(temporary)
    environment = {key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
    environment.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for case in args.only or CASES:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            directory = folder/(case+str(index)); directory.mkdir()
            config = directory/'global.config'; config.write_text('')
            private_temporary=directory/'temporary';private_temporary.mkdir(mode=0o700)
            private_home=directory/'home';private_home.mkdir(mode=0o700)
            environment.update(HOME=str(private_home), CFFIXED_USER_HOME=str(private_home), GIT_CONFIG_GLOBAL=str(config), XDG_CONFIG_HOME=str(directory/'xdg'), TMPDIR=str(private_temporary)+'/', TURTLEGIT_METAFILE_CASE=case)
            command = [str(receiver), str(directory), str(git.absolute())]
            command.append(str(root/'Tests/TurtleGitCoreTests/Fixtures/Metafile/ImageEffects'))
            environment.pop('TURTLEGIT_DRAWING_STATE_CAPTURES', None)
            if args.capture_dir and case == 'drawing-state' and index == 0:
                args.capture_dir.resolve().mkdir(parents=True, exist_ok=True)
                environment['TURTLEGIT_DRAWING_STATE_CAPTURES'] = str(args.capture_dir.resolve())
            print('Checking metafile '+case+' with '+str(git), flush=True)
            completed=False
            try:
                result = run_receiver(command, cwd=root, env=environment, capture_output=True, text=True,
                                      timeout_sample=directory/'timeout.sample.txt')
                print(result.stdout, end=''); print(result.stderr, end='')
                completed=result.returncode==0 and 'PASS: metafile workflow completed' in result.stdout
                if case=='image-effects':
                    results.append(dict(case=case,git=str(git.absolute()),returncode=result.returncode,passed=completed))
                    (root/'build/qa/metafile-image-effects-native-results.json').write_text(json.dumps(results,indent=2)+'\n')
                result.check_returncode()
                if not completed:raise SystemExit('Metafile receiver exited before completion: '+case)
            finally:
                if case=='image-effects':
                    sample=directory/'timeout.sample.txt'
                    if sample.is_file():shutil.copyfile(sample,root/('build/qa/metafile-image-effects-'+str(index)+'.sample.txt'))
                    approved={str(git.resolve())}
                    resolved=subprocess.run(['/usr/bin/xcrun','--find','git'],capture_output=True,text=True)
                    if resolved.returncode==0:approved.add(str(Path(resolved.stdout.strip()).resolve()))
                    for helper in [root/'build/metafile-runtime/Metafile/metafile-convert',root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/Metafile/metafile-convert']:
                        if helper.is_file():approved.add(str(helper.resolve()))
                    cleaned=retire_owned_helpers(directory,approved)
                    if completed and cleaned:
                        results[-1].update(passed=False,helper_cleanup_needed=True)
                        (root/'build/qa/metafile-image-effects-native-results.json').write_text(json.dumps(results,indent=2)+'\n')
                        raise RuntimeError('Owned helper outlived completed image-effect request')
