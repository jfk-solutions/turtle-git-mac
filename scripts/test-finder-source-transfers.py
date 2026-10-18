#!/usr/bin/env python3
"""One cached receiver for direct Finder source transfers and affected file workflows."""
import argparse
import hashlib
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = {
    'source': ('finder-source-transfer-native-2026-10-18.swift', 'FinderSourceTransferVerification.verify()'),
    'drop': ('file-drop-transfer-native-2026-10-14.swift', 'FileDropTransferVerification.verify()'),
    'move': ('file-move-native-2026-10-14.swift', 'FileMoveVerification.verify()'),
    'copy': ('file-transfer-native-2026-10-14.swift', 'FileTransferVerification.verify()'),
    'finder': ('finder-transfer-native-2026-10-14.swift', 'FinderTransferVerification.verify()'),
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
# Stable generated paths keep native_receiver's source-location cache entries
# reusable. Repositories, preferences and process working state stay private/run.
sources = {name: (root/'docs/qa'/name).read_text().replace('@main ', '', 1)
           for name, _ in CASES.values()}
digest = hashlib.sha256(Path(__file__).read_bytes())
for name, source in sorted(sources.items()):
    digest.update(name.encode()); digest.update(source.encode())
digest.update((root/'FinderSync/FinderSync.swift').read_bytes())
generated = root/'build/qa/native-fixtures/finder-source-transfers'/digest.hexdigest()
generated.mkdir(parents=True, exist_ok=True)
fixtures = []
for name, source in sources.items():
    path = generated/name
    if not path.exists() or path.read_text() != source: path.write_text(source)
    fixtures.append(path)
main = generated/'FinderSourceTransferMain.swift'
switch = ''.join('case "'+name+'": try await '+call+'; ' for name, (_, call) in CASES.items())
main.write_text('''import AppKit
import ObjectiveC
private extension NSWindow {
    @objc func turtleGitSourceTransferOrder(_ place: NSWindow.OrderingMode, relativeTo number: Int) {
        alphaValue = 0
        turtleGitSourceTransferOrder(place, relativeTo: number)
    }
}
@main enum FinderSourceTransferMain {
    @MainActor static func drain() async throws {
        for window in NSApp.windows {
            if let owner = window.delegate as? FileDropTransferWindowController { owner.close() }
            else if let owner = window.delegate as? FileMoveWindowController { owner.close() }
            else if let owner = window.delegate as? FileCopyWindowController { owner.close() }
        }
        try await FinderSourceTransferVerification.wait("retained operation cleanup") {
            FileDropTransferModel.activePreparations == 0 && FileDropTransferWindowController.activeReleases == 0 && FileMoveWindowModel.activeOperations == 0 && FileCopyWindowModel.activeOperations == 0
        }
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original = class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
        let hidden = class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitSourceTransferOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden)
        defer { method_exchangeImplementations(original,hidden) }
        let suite = "TurtleGit.TransferRunner."+UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        DialogGeometry.install(preferences:prefs)
        defer { prefs.removePersistentDomain(forName:suite) }
        do {
            switch ProcessInfo.processInfo.environment["TURTLEGIT_FINDER_SOURCE_CASE"]! { '''+switch+'''default: fatalError("Unknown transfer case") }
            try await drain()
        } catch { let failure=error; do {try await drain()}catch {throw error}; throw failure }
        print("PASS: Finder source transfer family completed")
    }
}
''')
receiver = build_receiver(root, fixtures+[root/'FinderSync/FinderSync.swift',main], generated)
env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),
           GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
for key in ['GIT_CONFIG_PARAMETERS','GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_AUTHOR_DATE','GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL','GIT_COMMITTER_DATE']:
    env.pop(key,None)
with tempfile.TemporaryDirectory(prefix='TurtleGit-FinderSource-') as temporary:
    directory = Path(temporary)
    for name in args.only or list(CASES):
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture = directory/(name+str(index)); fixture.mkdir()
            config = fixture/'global.config'; config.write_text('')
            env.update(GIT_CONFIG_GLOBAL=str(config),XDG_CONFIG_HOME=str(fixture/'xdg'),TURTLEGIT_FINDER_SOURCE_CASE=name)
            print('Checking Finder source transfer '+name+' with '+str(git), flush=True)
            result = run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True,timeout_sample=fixture/'timeout.sample.txt')
            print(result.stdout,end=''); print(result.stderr,end=''); result.check_returncode()
            if 'PASS: Finder source transfer family completed' not in result.stdout:
                raise SystemExit('Receiver exited before transfer completion: '+name)
