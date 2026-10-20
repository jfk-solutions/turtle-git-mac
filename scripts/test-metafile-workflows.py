#!/usr/bin/env python3
"""Grouped actual-renderer/native image workflows with reusable linked receivers."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = {
    'classic-pens': ('metafile-consumers-native-2026-10-18.swift', 'MetafileConsumersVerification'),
    'positioned-text': ('metafile-consumers-native-2026-10-18.swift', 'MetafileConsumersVerification'),
    'compressed-paths': ('metafile-consumers-native-2026-10-18.swift', 'MetafileConsumersVerification'),
    'consumers': ('metafile-consumers-native-2026-10-18.swift', 'MetafileConsumersVerification'),
    'conflict': ('image-conflict-native-2026-10-10.swift', 'ImageConflictVerification'),
    'conflict-owned': ('image-conflict-owned-native-2026-10-16.swift', 'ImageConflictOwnedVerification'),
    'frames': ('image-frames-native-2026-10-10.swift', 'ImageFramesVerification'),
    'colors': ('image-colors-native-2026-10-10.swift', 'ImageColorsVerification'),
    'toolbar': ('image-toolbar-native-2026-10-15.swift', 'ImageToolbarVerification'),
    'open': ('image-open-native-2026-10-10.swift', 'ImageOpenVerification'),
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
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
dispatch = '\n'.join('case "'+case+'": try await '+name+'.verify('+('classicPens:true' if case == 'classic-pens' else 'positionedText:true' if case == 'positioned-text' else 'compressedPaths:true' if case == 'compressed-paths' else '')+')' for case, (_, name) in CASES.items())
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
            environment.update(CFFIXED_USER_HOME=str(private_home), GIT_CONFIG_GLOBAL=str(config), XDG_CONFIG_HOME=str(directory/'xdg'), TMPDIR=str(private_temporary)+'/', TURTLEGIT_METAFILE_CASE=case)
            command = [str(receiver), str(directory), str(git.absolute())]
            if case in ['consumers','compressed-paths','positioned-text','classic-pens']: command.append(str(root/'Tests/TurtleGitCoreTests/Fixtures/Metafile'))
            print('Checking metafile '+case+' with '+str(git), flush=True)
            result = run_receiver(command, cwd=root, env=environment, capture_output=True, text=True,
                                  timeout_sample=directory/'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: metafile workflow completed' not in result.stdout:
                raise SystemExit('Metafile receiver exited before completion: '+case)
