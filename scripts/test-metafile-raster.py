#!/usr/bin/env python3
"""Grouped new classic Boolean WMF/EMF native comparison and conflict consumers."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = ['consumers', 'conflict']
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
generated = root / 'build/qa/metafile-raster-native-sources'
generated.mkdir(parents=True, exist_ok=True)
main = generated / 'MetafileRasterMain.swift'
source = '''import AppKit
import ObjectiveC
private extension NSWindow {
    @objc func turtleGitRasterOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000));turtleGitRasterOrder(place,relativeTo:number)
    }
}
@main struct MetafileRasterMain {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
        let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitRasterOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden)
        defer{method_exchangeImplementations(original,hidden)}
        try await ComparisonToolInvocation.$alternate.withValue(false) {
            switch ProcessInfo.processInfo.environment["TURTLEGIT_RASTER_CASE"]! {
            case "consumers":try await MetafileRasterVerification.consumers()
            case "conflict":try await MetafileRasterVerification.conflict()
            default:fatalError("Unknown ROP native case")
            }
        }
        print("PASS: Boolean metafile native case completed")
    }
}
'''
if not main.is_file() or main.read_text() != source:
    main.write_text(source)
receiver = build_receiver(root, [root / 'docs/qa/metafile-raster-native-2026-10-20.swift', main], generated)
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
                       XDG_CONFIG_HOME=str(xdg), TMPDIR=str(private_tmp) + '/', TURTLEGIT_RASTER_CASE=case)
            print('Checking Boolean metafile ' + case + ' with ' + str(git), flush=True)
            result = run_receiver([str(receiver), str(directory), str(git.absolute()),
                                   str(root / 'Tests/TurtleGitCoreTests/Fixtures/Metafile')], cwd=root, env=env,
                                  capture_output=True, text=True, timeout_sample=directory / 'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: Boolean metafile native case completed' not in result.stdout:
                raise SystemExit('Boolean metafile receiver exited before completion: ' + case)
