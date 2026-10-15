#!/usr/bin/env python3
"""Link native fixtures to built app objects; run grouped Merge/Patch/daemon/LFS/mail checks.

Daemon and LFS use injected responses. Mail uses only a private loopback SMTP fixture.
No installed app, Finder extension, real mail client or public server is invoked.
"""
from pathlib import Path
import ast
import base64
import hashlib
import json
import os
import platform
import signal
import subprocess
import tempfile
import time
import sys

root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
driver = ast.parse((root / 'scripts/test-synchronization-dialog.py').read_text())
cleanup_function = next(n for n in driver.body if isinstance(n, ast.FunctionDef) and n.name == 'close_receiver')
cleanup = {'os': os, 'signal': signal, 'time': time, 'subprocess': subprocess}
exec(compile(ast.Module(body=[cleanup_function], type_ignores=[]), '<owned native receiver cleanup>', 'exec'), cleanup)
close_receiver = cleanup['close_receiver']
with tempfile.TemporaryDirectory(prefix='TurtleGitLFSMailNativeBatch-') as temporary:
    folder = Path(temporary)
    objects = sorted((root / 'build/Build/Intermediates.noindex/TurtleGitMac.build/Debug/TurtleGitMac.build/Objects-normal' / platform.machine()).glob('*.o'))
    if not objects or not (products / 'TurtleGitMac.swiftmodule').exists():
        raise SystemExit('Build TurtleGitMac Debug before running native LFS/mail QA.')
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
    clipboard = folder / 'ClipboardReceiver.swift'
    clipboard.write_text((root / 'docs/qa/clipboard-target-native-2026-10-12.swift').read_text())
    regex = folder / 'MergeRegexReceiver.swift'
    regex.write_text((root / 'docs/qa/merge-regex-native-2026-10-12.swift').read_text().replace('@main struct', 'struct', 1))
    three_pane = folder / 'ThreePaneEngineReceiver.swift'
    three_pane.write_text((root / 'docs/qa/three-pane-engine-native-2026-10-12.swift').read_text().replace('@main struct', 'struct', 1))
    two_pane = folder / 'TwoPaneEngineReceiver.swift'
    two_pane.write_text((root / 'docs/qa/two-pane-engine-native-2026-10-12.swift').read_text().replace('@main struct', 'struct', 1))
    wrapping = folder / 'MergeWrappingReceiver.swift'
    wrapping.write_text((root / 'docs/qa/merge-wrapping-native-2026-10-12.swift').read_text())
    default_encoding = folder / 'MergeDefaultEncodingReceiver.swift'
    default_encoding.write_text((root / 'docs/qa/merge-default-encoding-native-2026-10-12.swift').read_text())
    one_pane_context = folder / 'MergeOnePaneContextReceiver.swift'
    one_pane_context.write_text((root / 'docs/qa/merge-one-pane-context-native-2026-10-12.swift').read_text())
    one_pane_receiver = folder / 'MergeOnePaneReceiver.swift'
    one_pane_receiver.write_text((root / 'docs/qa/merge-one-pane-native-2026-10-12.swift').read_text())
    colors_receiver = folder / 'MergeColorsReceiver.swift'
    colors_receiver.write_text((root / 'docs/qa/merge-colors-native-2026-10-12.swift').read_text())
    patch_receiver = folder / 'MergePatchReceiver.swift'
    patch_receiver.write_text((root / 'docs/qa/merge-patch-native-2026-10-12.swift').read_text())
    line_diff_receiver = folder / 'MergeLineDiffReceiver.swift'
    line_diff_receiver.write_text((root / 'docs/qa/merge-line-diff-native-2026-10-12.swift').read_text())
    format_receiver = folder / 'MergeFormatReceiver.swift'
    format_receiver.write_text((root / 'docs/qa/merge-format-native-2026-10-12.swift').read_text())
    open_receiver = folder / 'MergeOpenReceiver.swift'
    open_receiver.write_text((root / 'docs/qa/merge-open-native-2026-10-12.swift').read_text())
    find = folder / 'MergeFindReceiver.swift'
    find.write_text((root / 'docs/qa/merge-find-native-2026-10-12.swift').read_text())
    email = folder / 'EmailSettingsReceiver.swift'
    email.write_text((root / 'docs/qa/email-settings-native-2026-10-10.swift').read_text().replace('@main struct', 'struct', 1))
    fixtures = [lfs, mail, daemon, review, clipboard, regex, three_pane, two_pane, wrapping, default_encoding, one_pane_context, one_pane_receiver, colors_receiver, patch_receiver, line_diff_receiver, format_receiver, open_receiver, find, email]
    for fixture in fixtures:
        fixture.write_text('@testable import TurtleGitMac\n' + fixture.read_text())
    main = folder / 'Main.swift'
    main.write_text(r'''import AppKit
import Foundation
import TurtleGitCore
struct NativeBatch {
    @MainActor static func phase(_ name:String, _ body:() async throws -> Void) async throws {
        let file = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("phase.json")
        try JSONSerialization.data(withJSONObject:["phase":name,"status":"running"]).write(to:file,options:.atomic)
        print("Native phase started: " + name); fflush(stdout)
        do { try await body() }
        catch {
            try? JSONSerialization.data(withJSONObject:["phase":name,"status":"failed","error":String(describing:error)]).write(to:file,options:.atomic)
            throw error
        }
        try JSONSerialization.data(withJSONObject:["phase":name,"status":"completed"]).write(to:file,options:.atomic)
        print("Native phase completed: " + name); fflush(stdout)
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        if CommandLine.arguments.contains("--states-only") {
            try await phase("ThreePaneEngineVerification") { try await ThreePaneEngineVerification.verify(configuration: SubversionMergeConfiguration.bundled()) }
            try await phase("TwoPaneEngineVerification") { try await TwoPaneEngineVerification.verify() }
            try await phase("MergeFindNativeVerification") { try await MergeFindNativeVerification.verify() }
            try await phase("MergeColorsNativeVerification") { try await MergeColorsNativeVerification.verify() }
            try await phase("ClipboardTargetNativeVerification") { try await ClipboardTargetNativeVerification.verify() }
            return
        }
        if CommandLine.arguments.contains("--email-only") { try await phase("EmailSettingsVerification") { try await EmailSettingsVerification.verify() }; return }
        if CommandLine.arguments.contains("--lfs-only") { try await phase("LFSLocksVerification") { try await LFSLocksVerification.main() }; return }
        if !CommandLine.arguments.contains("--lfs-mail-only") {
        try await phase("MergeRegexNativeVerification") { try await MergeRegexNativeVerification.verify(parser: URL(fileURLWithPath: CommandLine.arguments[5])) }
        try await phase("ThreePaneEngineVerification") { try await ThreePaneEngineVerification.verify(configuration: SubversionMergeConfiguration.bundled()) }
        try await phase("TwoPaneEngineVerification") { try await TwoPaneEngineVerification.verify() }
        try await phase("MergeFindNativeVerification") { try await MergeFindNativeVerification.verify() }
        try await phase("MergeOpenNativeVerification") { try await MergeOpenNativeVerification.verify() }
        try await phase("MergeFormatNativeVerification") { try await MergeFormatNativeVerification.verify() }
        try await phase("MergeLineDiffNativeVerification") { try await MergeLineDiffNativeVerification.verify() }
        try await phase("MergePatchNativeVerification") { try await MergePatchNativeVerification.verify() }
        try await phase("MergeColorsNativeVerification") { try await MergeColorsNativeVerification.verify() }
        try await phase("MergeOnePaneNativeVerification") { try await MergeOnePaneNativeVerification.verify() }
        try await phase("MergeOnePaneContextVerification") { try await MergeOnePaneContextVerification.verify() }
        try await phase("MergeDefaultEncodingVerification") { try await MergeDefaultEncodingVerification.verify() }
        try await phase("MergeWrappingVerification") { try await MergeWrappingVerification.verify() }
        try await phase("ClipboardTargetNativeVerification") { try await ClipboardTargetNativeVerification.verify() }
        try await phase("ReviewPatchNativeVerification") { try await ReviewPatchNativeVerification.verify() }
        try await phase("DaemonNativeVerification") { try await DaemonNativeVerification.verify() }
        }
        try await phase("LFSLocksVerification") { try await LFSLocksVerification.main() }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        try Data().write(to: fixture.appendingPathComponent("lfs-done"))
        for _ in 0..<1000 {
            if FileManager.default.fileExists(atPath: fixture.appendingPathComponent("ready.json").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await phase("SendPatchVerification") { try await SendPatchVerification.verify() }
    }
}

@_cdecl("turtlegit_lfs_mail_batch_main") func bootstrap() -> Int32 {
    NSApplication.shared.setActivationPolicy(.prohibited)
    Task { @MainActor in
        do { try await NativeBatch.main(); exit(0) }
        catch { fputs("Native batch failed: \(error)\n",stderr); exit(1) }
    }
    NSApplication.shared.run(); return 0
}
''')
    digest = hashlib.sha256()
    digest.update((platform.machine() + '-apple-macos13.0/swift5/WMO-Onone/lfs-mail-objects-v1').encode())
    digest.update(subprocess.check_output(['xcrun', 'swiftc', '--version']))
    inputs = [*objects, *fixtures, main]
    for imported in [products / 'TurtleGitCore.framework', products / 'TurtleGitMac.swiftmodule']:
        inputs += sorted(p for p in imported.rglob('*') if p.is_file() and not p.is_symlink())
    for source in inputs:
        digest.update(source.name.encode()); digest.update(source.read_bytes())
    cache = root / 'build/qa/native-receivers'; cache.mkdir(parents=True, exist_ok=True)
    executable = cache / ('lfs-mail-' + digest.hexdigest())
    if not executable.exists():
        staging = folder / 'verify'
        compiler = subprocess.Popen(['xcrun', 'swiftc', '-whole-module-optimization', '-Onone', '-parse-as-library', '-swift-version', '5',
                        '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products),
                        *map(str, fixtures), str(main), *map(str, objects), '-framework', 'TurtleGitCore', '-Xlinker', '-rpath', '-Xlinker', str(products), '-Xlinker', '-e', '-Xlinker', '_turtlegit_lfs_mail_batch_main', '-o', str(staging)], cwd=root, start_new_session=True)
        try:
            # Hosted Intel runners can need more than five minutes to type-check
            # the grouped receiver module. Bound compilation separately from
            # each runtime phase; always reap its process group below.
            code = compiler.wait(timeout=900)
            if code: raise subprocess.CalledProcessError(code, compiler.args)
        finally:
            close_receiver(compiler)
            print('Owned fixture compiler reaped: ' + str(compiler.pid), flush=True)
        staging.replace(executable)
        print('Native fixtures linked once to the current Debug app objects.', flush=True)
    else: print('Reusing native receiver for unchanged objects/modules/fixtures/toolchain.', flush=True)
    mail_fixture = folder / 'mail'; mail_fixture.mkdir()
    lfs_fixture = folder / 'lfs'; lfs_fixture.mkdir()
    environment = os.environ.copy()
    environment.update(DYLD_FRAMEWORK_PATH=str(products), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    for variable in ['GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL']: environment.pop(variable, None)
    if any(mode in sys.argv for mode in ['--lfs-only', '--email-only', '--states-only']):
        mode = '--states-only' if '--states-only' in sys.argv else '--email-only' if '--email-only' in sys.argv else '--lfs-only'
        receiver = subprocess.Popen([str(executable), str(mail_fixture), '0', str(lfs_fixture), '/usr/bin/git', str(products / 'TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex'), mode], cwd=root, env=environment, start_new_session=True)
        try:
            try: code = receiver.wait(timeout=300 if mode == '--states-only' else 120)
            except subprocess.TimeoutExpired as error:
                phase_file = mail_fixture / 'phase.json'
                phase = phase_file.read_text() if phase_file.exists() else 'not published'
                raise RuntimeError('Focused native phase timed out: phase=' + phase + ', pid=' + str(receiver.pid)) from error
            if code: raise subprocess.CalledProcessError(code, receiver.args)
        finally:
            close_receiver(receiver)
            print('Owned native receiver reaped: ' + str(receiver.pid), flush=True)
        raise SystemExit(0)
    receiver = subprocess.Popen([str(executable), str(mail_fixture), '0', str(lfs_fixture), '/usr/bin/git', str(products / 'TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex'), *(['--lfs-mail-only'] if '--lfs-mail-only' in sys.argv else [])], cwd=root, env=environment, start_new_session=True)
    server = None
    try:
        deadline = time.monotonic() + 120
        total_deadline = time.monotonic() + 600
        current_phase = None
        phase_file = mail_fixture / 'phase.json'
        while not (mail_fixture / 'lfs-done').exists():
            code = receiver.poll()
            try: phase = json.loads(phase_file.read_text())
            except (FileNotFoundError, json.JSONDecodeError): phase = None
            if phase and phase['phase'] != current_phase:
                current_phase = phase['phase']; deadline = time.monotonic() + 120
                print('Waiting for native phase: ' + current_phase, flush=True)
            if code is not None:
                raise RuntimeError('Native receiver exited before SMTP readiness: exit=' + str(code) + ', phase=' + str(phase))
            if time.monotonic() >= deadline or time.monotonic() >= total_deadline:
                raise RuntimeError('Native phase timed out before SMTP readiness: phase=' + str(phase) + ', pid=' + str(receiver.pid))
            time.sleep(.05)
        server = subprocess.Popen(['/usr/bin/python3', str(root / 'Tests/TurtleGitCoreTests/Fixtures/smtp_server.py'), str(mail_fixture), 'normal', '60'], start_new_session=True)
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
        close_receiver(receiver)
        print('Owned native receiver reaped: ' + str(receiver.pid), flush=True)
        if server is not None:
            close_receiver(server)
            print('Owned SMTP fixture reaped: ' + str(server.pid), flush=True)
