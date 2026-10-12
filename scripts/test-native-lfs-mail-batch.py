#!/usr/bin/env python3
"""Compile native receivers once, then run daemon, LFS and mail checks in one process.

Daemon and LFS use injected responses. Mail uses only a private loopback SMTP fixture.
No installed app, Finder extension, real mail client or public server is invoked.
"""
from pathlib import Path
import base64
import hashlib
import json
import os
import platform
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='TurtleGitLFSMailNativeBatch-') as temporary:
    folder = Path(temporary)
    app = root / 'Sources/TurtleGitMac/TurtleGitMacApp.swift'
    copy = folder / app.name
    copy.write_text(app.read_text().replace('@main struct', 'struct', 1))
    lfs = folder / 'LFSReceiver.swift'
    lfs.write_text((root / 'docs/qa/lfs-locks-native-2026-10-08.swift').read_text()
                   .replace('@main struct', 'struct', 1)
                   .replace('CommandLine.arguments[1]', 'CommandLine.arguments[3]')
                   .replace('CommandLine.arguments[2]', 'CommandLine.arguments[4]'))
    mail = folder / 'MailReceiver.swift'
    mail.write_text((root / 'docs/qa/send-patch-dialog-native-2026-10-10.swift').read_text()
                    .replace('@main struct', 'struct', 1)
                    .replace('NSApplication.shared.setActivationPolicy(.prohibited)', 'NSApplication.shared.setActivationPolicy(.prohibited); unsetenv("GIT_AUTHOR_NAME"); unsetenv("GIT_AUTHOR_EMAIL"); setenv("GIT_AUTHOR_NAME", "", 1); setenv("GIT_AUTHOR_EMAIL", "", 1)')
                    .replace('guard CommandLine.arguments.count == 3, let port = Int(CommandLine.arguments[2]) else', 'guard let port = (try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("ready.json"))) as? [String: Any])?["port"] as? Int else'))
    daemon = folder / 'DaemonReceiver.swift'
    daemon.write_text((root / 'docs/qa/daemon-native-2026-10-12.swift').read_text())
    review = folder / 'ReviewReceiver.swift'
    review.write_text((root / 'docs/qa/review-patch-native-2026-10-12.swift').read_text())
    svn = folder / 'SVNReceiver.swift'
    svn.write_text((root / 'docs/qa/svn-native-2026-10-12.swift').read_text())
    svn_fixture = folder / 'SVNFixture.swift'
    svn_fixture.write_text((root / 'Tests/TurtleGitCoreTests/GitSVNFixture.swift').read_text().replace('@testable import TurtleGitCore', 'import TurtleGitCore'))
    clipboard = folder / 'ClipboardReceiver.swift'
    clipboard.write_text((root / 'docs/qa/clipboard-target-native-2026-10-12.swift').read_text())
    regex = folder / 'MergeRegexReceiver.swift'
    regex.write_text((root / 'docs/qa/merge-regex-native-2026-10-12.swift').read_text().replace('@main struct', 'struct', 1))
    three_pane = folder / 'ThreePaneEngineReceiver.swift'
    three_pane.write_text((root / 'docs/qa/three-pane-engine-native-2026-10-12.swift').read_text().replace('@main struct', 'struct', 1))
    main = folder / 'Main.swift'
    main.write_text('''import AppKit
import Foundation
import TurtleGitCore
@main struct NativeBatch {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try await MergeRegexNativeVerification.verify(parser: URL(fileURLWithPath: CommandLine.arguments[5]))
        try await ThreePaneEngineVerification.verify(configuration: SubversionMergeConfiguration.bundled())
        try await ClipboardTargetNativeVerification.verify()
        try await SVNNativeVerification.verify()
        try await ReviewPatchNativeVerification.verify()
        try await DaemonNativeVerification.verify()
        try await LFSLocksVerification.main()
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        try Data().write(to: fixture.appendingPathComponent("lfs-done"))
        for _ in 0..<1000 {
            if FileManager.default.fileExists(atPath: fixture.appendingPathComponent("ready.json").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await SendPatchVerification.verify()
    }
}
''')
    sources = sorted(str(p) for p in (root / 'Sources/TurtleGitMac').glob('*.swift') if p != app)
    digest = hashlib.sha256()
    digest.update((platform.machine() + '-apple-macos13.0/swift5/WMO-Onone/testing-receiver-v2').encode())
    digest.update(subprocess.check_output(['xcrun', 'swiftc', '--version']))
    for source in [*map(Path, sources), copy, lfs, mail, daemon, review, svn, svn_fixture, clipboard, regex, three_pane, main, products / 'TurtleGitCore.framework/TurtleGitCore']:
        digest.update(source.name.encode()); digest.update(source.read_bytes())
    cache = root / 'build/qa/native-receivers'; cache.mkdir(parents=True, exist_ok=True)
    executable = cache / ('lfs-mail-' + digest.hexdigest())
    if not executable.exists():
        staging = folder / 'verify'
        subprocess.run(['xcrun', 'swiftc', '-whole-module-optimization', '-Onone', '-parse-as-library', '-swift-version', '5',
                        '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products),
                        *sources, str(copy), str(lfs), str(mail), str(daemon), str(review), str(svn), str(svn_fixture), str(clipboard), str(regex), str(three_pane), str(main), '-framework', 'TurtleGitCore', '-o', str(staging)], cwd=root, check=True)
        staging.replace(executable)
        print('Native receiver compiled once for this source/framework/toolchain.', flush=True)
    else: print('Reusing native receiver for unchanged source/framework/toolchain.', flush=True)
    mail_fixture = folder / 'mail'; mail_fixture.mkdir()
    lfs_fixture = folder / 'lfs'; lfs_fixture.mkdir()
    environment = os.environ.copy()
    environment.update(DYLD_FRAMEWORK_PATH=str(products), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    for variable in ['GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL']: environment.pop(variable, None)
    receiver = subprocess.Popen([str(executable), str(mail_fixture), '0', str(lfs_fixture), '/usr/bin/git', str(products / 'TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex')], cwd=root, env=environment)
    server = None
    try:
        deadline = time.monotonic() + 90
        while not (mail_fixture / 'lfs-done').exists() and receiver.poll() is None and time.monotonic() < deadline: time.sleep(.05)
        if not (mail_fixture / 'lfs-done').exists(): raise RuntimeError('LFS receiver did not complete; mail server was not started')
        server = subprocess.Popen(['/usr/bin/python3', str(root / 'Tests/TurtleGitCoreTests/Fixtures/smtp_server.py'), str(mail_fixture), 'normal', '60'])
        if receiver.wait(timeout=120) != 0: raise RuntimeError('Native batch receiver failed')
        assert server.wait(timeout=10) == 0
        state = json.loads((mail_fixture / 'result.json').read_text())
        assert state['accepted'] == 1 and state['auth'] == 0 and state['data'] == 1
        assert state['recipients'] == ['RCPT TO:<to@example.invalid>', 'RCPT TO:<cc@example.invalid>']
        assert len(state['parts']) == 3
        assert base64.b64decode(state['parts'][0]['payload']) == (mail_fixture / 'expected-body').read_bytes()
        for part in state['parts'][1:]:
            assert part['filename'] == '2.patch'
            assert base64.b64decode(part['payload']) == (mail_fixture / 'expected-attachment').read_bytes()
        print('Grouped native daemon/LFS/mail receiver: one compilation, one verification process; private SMTP MIME verified and owned resources cleaned.')
    finally:
        if receiver.poll() is None: receiver.terminate()
        receiver.wait(timeout=10)
        if server is not None:
            if server.poll() is None: server.terminate()
            server.wait(timeout=10)
