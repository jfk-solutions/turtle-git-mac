#!/usr/bin/env python3
"""Grouped new raster ROI/checkpoint WMF/EMF native comparison and conflict consumers."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import time
import tempfile
from native_receiver import build_receiver, run_receiver

def retire_owned_metafile_helpers(context, approved):
    """Private request open files AND exact approved executable identify ownership."""
    def owned():
        holders = subprocess.run(['/usr/sbin/lsof', '-t', '+D', str(context)], capture_output=True, text=True, timeout=10)
        if holders.returncode not in (0, 1):
            raise RuntimeError('Could not inspect private metafile request ownership')
        result = []
        for value in set(holders.stdout.split()):
            pid = int(value)
            text = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'txt', '-Fn'], capture_output=True, text=True, timeout=5)
            images = {str(Path(line[1:]).resolve()) for line in text.stdout.splitlines() if line.startswith('n')}
            if images.intersection(approved):
                result.append(pid)
        return result
    leftovers = owned()
    needed_cleanup = bool(leftovers)
    for number in [signal.SIGTERM, signal.SIGKILL]:
        for pid in leftovers:
            # Revalidate the open request and executable before signaling a PID.
            if pid not in owned():
                continue
            try:
                group = os.getpgid(pid)
                os.killpg(group, number) if group == pid else os.kill(pid, number)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            leftovers = owned()
            if not leftovers:
                break
            time.sleep(.03)
        if not leftovers:
            break
    if leftovers:
        raise RuntimeError('Owned approved metafile helper survived cleanup: ' + str(leftovers))
    return needed_cleanup


CASES = ['consumers', 'conflict']
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
approved = {str(path.resolve()) for path in [
    root / 'build/metafile-runtime/Metafile/metafile-convert',
    root / 'build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/Metafile/metafile-convert',
] if path.is_file()}
generated = root / 'build/qa/metafile-raster-roi-native-sources'
generated.mkdir(parents=True, exist_ok=True)
main = generated / 'MetafileRasterROIMain.swift'
source = '''import AppKit
import ObjectiveC
private extension NSWindow {
    @objc func turtleGitRasterROIOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000));turtleGitRasterROIOrder(place,relativeTo:number)
    }
}
@main struct MetafileRasterROIMain {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
        let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitRasterROIOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden)
        defer{method_exchangeImplementations(original,hidden)}
        try await ComparisonToolInvocation.$alternate.withValue(false) {
            switch ProcessInfo.processInfo.environment["TURTLEGIT_RASTER_ROI_CASE"]! {
            case "consumers":try await MetafileRasterROIVerification.consumers()
            case "conflict":try await MetafileRasterROIVerification.conflict()
            default:fatalError("Unknown ROP native case")
            }
        }
        print("PASS: ROI metafile native case completed")
    }
}
'''
if not main.is_file() or main.read_text() != source:
    main.write_text(source)
receiver = build_receiver(root, [root / 'docs/qa/metafile-raster-roi-native-2026-10-21.swift', main], generated)
with tempfile.TemporaryDirectory(prefix='turtlegit-raster-native-') as temporary:
    for case in args.only or CASES:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            directory = Path(temporary) / (case + str(index)); directory.mkdir(mode=0o700)
            private_tmp = directory / 'temporary'; private_tmp.mkdir(mode=0o700)
            private_home = directory / 'home'; private_home.mkdir(mode=0o700)
            xdg = directory / 'xdg'; xdg.mkdir(mode=0o700)
            config = directory / 'global.config'; config.write_text('')
            env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            env.update(DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=str(config),
                       GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0', CFFIXED_USER_HOME=str(private_home),
                       XDG_CONFIG_HOME=str(xdg), TMPDIR=str(private_tmp) + '/', TURTLEGIT_RASTER_ROI_CASE=case)
            print('Checking ROI metafile ' + case + ' with ' + str(git), flush=True)
            completed = False
            try:
                result = run_receiver([str(receiver), str(directory), str(git.absolute()),
                                       str(root / 'Tests/TurtleGitCoreTests/Fixtures/Metafile')], cwd=root, env=env,
                                      capture_output=True, text=True, timeout_sample=root / ('build/qa/metafile-raster-roi-' + case + '-' + str(index) + '.timeout.sample.txt'))
                print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
                if 'PASS: ROI metafile native case completed' not in result.stdout:
                    raise SystemExit('ROI metafile receiver exited before completion: ' + case)
                completed = True
            finally:
                cleaned = retire_owned_metafile_helpers(directory, approved)
                if completed and cleaned:
                    raise RuntimeError('Approved metafile helper outlived a completed native ROI request')
