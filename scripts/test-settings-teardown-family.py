#!/usr/bin/env python3
"""One cached receiver for Settings graph teardown and affected native lifecycle consumers."""
import argparse
import hashlib
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = {
    'teardown': ('settings-teardown-native-2026-10-18.swift', 'SettingsTeardownVerification.verify()'),
    'replay': ('replay-hook-identity-native-2026-10-18.swift', 'ReplayHookIdentityVerification.verify()'),
    'configuration': ('configuration-lifecycle-native-2026-10-15.swift', 'ConfigurationLifecycleVerification.main()'),
    'git': ('git-config-source-native-2026-10-17.swift', 'GitConfigSourceVerification.verify()'),
    'credential': ('credential-source-family-native-2026-10-17.swift', 'CredentialSourceFamilyVerification.verify()'),
    'network': ('network-source-family-native-2026-10-17.swift', 'NetworkSourceFamilyVerification.verify()'),
    'general': ('general-source-family-native-2026-10-17.swift', 'GeneralSourceVerification.verify()'),
    'finder': ('context-menu-source-native-2026-10-17.swift', 'FinderMenuSourceVerification.verify()'),
    'merge': ('merge-general-native-2026-10-12.swift', 'MergeGeneralVerification.verify()'),
    'remote': ('remote-list-native-2026-10-18.swift', 'RemoteListVerification.verify()'),
    'properties': ('settings-sheet-family-native-2026-10-18.swift', 'SettingsSheetFamilyVerification.verify(properties:true)'),
    'email': ('email-credential-editor-native-2026-10-17.swift', 'EmailCredentialEditorVerification.verify()'),
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
# Stable generated paths keep native_receiver's source-location cache entries
# reusable. Repositories, preferences and process working state stay private/run.
# Merge General reuses the production comparison fixture's settled/editor helpers.
# Compile that dependency without adding its separate workflow to this group.
helper_sources = ['two-pane-engine-native-2026-10-12.swift']
source_names = [name for name, _ in CASES.values()] + helper_sources
sources = {name: (root/'docs/qa'/name).read_text().replace('@main ', '', 1)
           for name in source_names}
digest = hashlib.sha256(Path(__file__).read_bytes())
for name, source in sorted(sources.items()):
    digest.update(name.encode()); digest.update(source.encode())
generated = root/'build/qa/native-fixtures/settings-teardown-family'/digest.hexdigest()
generated.mkdir(parents=True, exist_ok=True)
fixtures = []
for name, source in sources.items():
    path = generated/name
    if not path.exists() or path.read_text() != source: path.write_text(source)
    fixtures.append(path)
main = generated/'SettingsTeardownMain.swift'
switch = ''.join('case "'+name+'": try await '+call+'; ' for name, (_, call) in CASES.items())
main.write_text('''import AppKit
import ObjectiveC
private extension NSWindow {
    @objc func turtleGitSettingsTeardownOrder(_ place: NSWindow.OrderingMode, relativeTo number: Int) {
        alphaValue = 0
        turtleGitSettingsTeardownOrder(place, relativeTo: number)
    }
}
@main enum SettingsTeardownMain {
    @MainActor static func drain() async throws {
        ClientHookProcessPool.shared.cancelAll()
        for window in NSApp.windows { window.contentViewController = nil; window.close() }
        try await SettingsTeardownVerification.drain()

    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original = class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
        let hidden = class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitSettingsTeardownOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden)
        defer { method_exchangeImplementations(original,hidden) }
        let suite = "TurtleGit.SettingsTeardownRunner."+UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        DialogGeometry.install(preferences:prefs)
        defer { prefs.removePersistentDomain(forName:suite) }
        do {
            switch ProcessInfo.processInfo.environment["TURTLEGIT_SETTINGS_TEARDOWN_CASE"]! { '''+switch+'''default: fatalError("Unknown settings case") }
            try await drain()
        } catch { let failure=error; do {try await drain()}catch {throw error}; throw failure }
        print("PASS: Settings teardown family completed")
    }
}
''')
receiver = build_receiver(root, fixtures+[main], generated)
env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),
           GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
for key in ['GIT_CONFIG_PARAMETERS','GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_AUTHOR_DATE','GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL','GIT_COMMITTER_DATE']:
    env.pop(key,None)
for key in list(env):
    if key.startswith('TURTLEGIT_') and ('CAPTURE' in key or 'SCREENSHOT' in key): env.pop(key,None)
with tempfile.TemporaryDirectory(prefix='TurtleGit-SettingsTeardown-') as temporary:
    directory = Path(temporary)
    for name in args.only or list(CASES):
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture = directory/(name+str(index)); fixture.mkdir()
            config = fixture/'global.config'; config.write_text('')
            env.update(GIT_CONFIG_GLOBAL=str(config),XDG_CONFIG_HOME=str(fixture/'xdg'),TURTLEGIT_SETTINGS_TEARDOWN_CASE=name)
            print('Checking Settings teardown '+name+' with '+str(git), flush=True)
            result = run_receiver([str(receiver),str(fixture),str(git.absolute())],cwd=root,env=env,capture_output=True,text=True,timeout_sample=fixture/'timeout.sample.txt')
            print(result.stdout,end=''); print(result.stderr,end=''); result.check_returncode()
            if 'PASS: Settings teardown family completed' not in result.stdout:
                raise SystemExit('Receiver exited before settings completion: '+name)
