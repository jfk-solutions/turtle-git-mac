#!/usr/bin/env python3
"""First-use comparison, patch/mail and repository delivery Services; hidden native owners."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
from native_receiver import build_receiver, run_receiver

def retire_private_git(context, approved):
    """An open private request/repository AND exact Git image prove ownership."""
    def owned():
        result = subprocess.run(['/usr/sbin/lsof', '-t', '+D', str(context)], capture_output=True, text=True, timeout=10)
        if result.returncode not in (0, 1):
            raise RuntimeError('Cannot inspect private delivery helper ownership')
        pids = []
        for value in set(result.stdout.split()):
            pid = int(value)
            image = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'txt', '-Fn'], capture_output=True, text=True, timeout=5)
            paths = {str(Path(line[1:]).resolve()) for line in image.stdout.splitlines() if line.startswith('n')}
            if paths.intersection(approved):
                pids.append(pid)
        return pids
    needed = bool(owned())
    for number in [signal.SIGTERM, signal.SIGKILL]:
        for pid in owned():
            if pid not in owned():
                continue
            try:
                group = os.getpgid(pid)
                os.killpg(group, number) if group == pid else os.kill(pid, number)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 3
        while owned() and time.monotonic() < deadline:
            time.sleep(.03)
        if not owned():
            break
    if owned():
        raise RuntimeError('Verified private Git helper survived delivery cleanup')
    return needed

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['provider', 'files', 'routes', 'owners'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
generated = root / 'build/qa/finder-delivery-services-native-sources'
generated.mkdir(parents=True, exist_ok=True)
main = generated / 'FinderDeliveryServicesMain.swift'
source = '''import AppKit
import ObjectiveC
import TurtleGitCore
private extension NSWindow {
    @objc func turtleGitDeliveryOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000));turtleGitDeliveryOrder(place,relativeTo:number)
    }
}
@main struct FinderDeliveryServicesMain {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
        let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitDeliveryOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden)
        defer{method_exchangeImplementations(original,hidden)}
        let geometrySuite="TurtleGit.Delivery.Geometry.QA."+UUID().uuidString
        let geometry=UserDefaults(suiteName:geometrySuite)!
        DialogGeometry.install(preferences:geometry)
        defer{DialogGeometry.install(preferences:.standard);geometry.removePersistentDomain(forName:geometrySuite)}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        switch ProcessInfo.processInfo.environment["TURTLEGIT_FINDER_DELIVERY_CASE"]! {
        case "provider":try await FinderDeliveryRepositoryVerification.provider(root:root,git:git,plist:URL(fileURLWithPath:CommandLine.arguments[3]))
        case "files":try await FinderDeliveryFilesVerification.run(root:root,git:git)
        case "routes":try await FinderDeliveryRepositoryVerification.routes(root:root,git:git)
        case "owners":try await FinderDeliveryOwnersVerification.run(root:root,git:git)
        default:fatalError("Unknown delivery Service case")
        }
        print("PASS: Finder delivery Services case completed")
    }
}
'''
if not main.is_file() or main.read_text() != source:
    main.write_text(source)
fixtures = [root / ('docs/qa/finder-delivery-' + name + '-native-2026-10-21.swift') for name in ['files', 'repository', 'owners']]
receiver = build_receiver(root, [*fixtures, main], generated)
engines = args.git or [Path('/usr/bin/git')]
system_git = subprocess.check_output(['/usr/bin/xcrun', '--find', 'git'], text=True).strip()
approved = {str(path.resolve()) for path in [*engines, Path(system_git), root / 'build/git-runtime/Git/bin/git'] if path.is_file()}
with tempfile.TemporaryDirectory(prefix='turtlegit-finder-delivery-') as temporary:
    for case in args.only or ['provider', 'files', 'routes', 'owners']:
        for index, git in enumerate(engines[:1] if case == 'provider' else engines):
            context = Path(temporary) / (case + str(index)); context.mkdir(mode=0o700)
            fixture = context / 'fixture'; fixture.mkdir(mode=0o700)
            private_tmp = context / 'temporary'; private_tmp.mkdir(mode=0o700)
            preferences = context / 'preferences'; preferences.mkdir(mode=0o700)
            xdg = context / 'xdg'; xdg.mkdir(mode=0o700)
            config = context / 'global.config'; config.write_text('')
            env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            env.update(DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=str(config),
                       GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0', CFFIXED_USER_HOME=str(preferences),
                       XDG_CONFIG_HOME=str(xdg), TMPDIR=str(private_tmp)+'/', TURTLEGIT_FINDER_DELIVERY_CASE=case)
            print('Checking delivery Finder Services ' + case + ' with ' + str(git), flush=True)
            completed = False
            try:
                result = run_receiver([str(receiver), str(fixture), str(git.absolute()), str(root / 'Configuration/App-Info.plist')],
                                      cwd=root, env=env, capture_output=True, text=True,
                                      timeout_sample=root / ('build/qa/finder-delivery-' + case + '-' + str(index) + '.sample.txt'))
                print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
                if 'PASS: Finder delivery Services case completed' not in result.stdout:
                    raise SystemExit('Delivery Service receiver exited before completion')
                completed = True
            finally:
                if retire_private_git(context, approved) and completed:
                    raise RuntimeError('Completed delivery Service left a test-owned Git helper alive')
