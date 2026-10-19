#!/usr/bin/env python3
"""Grouped native failed-Pick, cleanup retry and replay prompt ownership checks."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--captures', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
sources = root/'build/qa/rebase-execution-recovery-sources'
sources.mkdir(parents=True, exist_ok=True)
fixture = sources/'RebaseExecutionRecoveryFixture.swift'
contents = (root/'docs/qa/rebase-execution-recovery-native-2026-10-19.swift').read_text().replace('@main ', '', 1)
if not fixture.is_file() or fixture.read_text() != contents:
    fixture.write_text(contents)
main = sources/'RebaseExecutionRecoveryMain.swift'
contents = '''import AppKit
import ObjectiveC
private extension NSWindow {
    @objc func turtleGitRecoveryOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000))
        turtleGitRecoveryOrder(place,relativeTo:number)
    }
}
@main struct RebaseExecutionRecoveryMain {
    @MainActor static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
        let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitRecoveryOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden)
        defer {method_exchangeImplementations(original,hidden)}
        try await RebaseExecutionRecoveryVerification.main()
    }
}
'''
if not main.is_file() or main.read_text() != contents:
    main.write_text(contents)
receiver = build_receiver(root, [fixture, main], sources)
editor = root/'build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac'
with tempfile.TemporaryDirectory(prefix='turtlegit-rebase-recovery-') as temporary:
    directory = Path(temporary)
    base = {key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
    base.pop('TURTLEGIT_REBASE_RECOVERY_CAPTURES', None)
    base.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        private = directory/str(index);private.mkdir()
        config = private/'global.config';config.write_text('')
        private_tmp = private/'temporary';private_tmp.mkdir(mode=0o700)
        env = dict(base, GIT_CONFIG_GLOBAL=str(config), XDG_CONFIG_HOME=str(private/'xdg'), TMPDIR=str(private_tmp)+'/')
        if args.captures and index == 0:
            env['TURTLEGIT_REBASE_RECOVERY_CAPTURES'] = str(args.captures.absolute())
        print('Checking Rebase execution recovery with '+str(git), flush=True)
        result = run_receiver([str(receiver), str(private), str(git.absolute()), str(editor)], cwd=root, env=env, capture_output=True, text=True, timeout_sample=private/'timeout.sample.txt')
        print(result.stdout, end='');print(result.stderr, end='');result.check_returncode()
        marker = 'PASS: Rebase recovery capture acceptance' if env.get('TURTLEGIT_REBASE_RECOVERY_CAPTURES_ONLY') == '1' else 'PASS: Rebase execution recovery'
        if marker not in result.stdout:
            raise SystemExit('Rebase recovery receiver exited before completion')
