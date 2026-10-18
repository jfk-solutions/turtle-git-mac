#!/usr/bin/env python3
"""Captured Settings sheet callers and retained owner workflows."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

CASES = {
    'properties': 'SettingsSheetFamilyVerification.verify(properties: true)',
    'patch': 'SettingsSheetFamilyVerification.verify(properties: false)',
    'replay': 'ReplayHookIdentityVerification.verify()',
    'properties-retained': 'GitPropertiesVerification.verify()',
    'document-retained': 'UnifiedDocumentVerification.verify()',
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-settings-sheets-') as temporary:
    directory = Path(temporary)
    sources = []
    for filename in ['settings-sheet-family-native-2026-10-18.swift', 'replay-hook-identity-native-2026-10-18.swift', 'git-properties-native-2026-10-13.swift', 'unified-document-native-2026-10-15.swift']:
        source = directory/filename
        source.write_text((root/'docs/qa'/filename).read_text().replace('@main ', '', 1))
        sources.append(source)
    main = directory/'SettingsSheetMain.swift'
    cases = ''.join('case "'+case+'": try await '+call+';' for case, call in CASES.items())
    main.write_text('import AppKit\n@main struct SettingsSheetMain { @MainActor static func main() async throws { NSApplication.shared.setActivationPolicy(.prohibited); switch ProcessInfo.processInfo.environment["TURTLEGIT_SETTINGS_SHEET_CASE"]! { '+cases+' default: fatalError("Unknown case") }; print("PASS: Settings sheet case completed") } }\n')
    receiver = build_receiver(root, sources+[main], directory)
    env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    env.pop('TURTLEGIT_UNIFIED_DOCUMENT_CAPTURE', None)
    for case in args.only or ['properties', 'patch']:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            folder = directory/(case+str(index)); folder.mkdir()
            env['TURTLEGIT_SETTINGS_SHEET_CASE'] = case
            print('Checking Settings sheet '+case+' with '+str(git), flush=True)
            result = run_receiver([str(receiver), str(folder), str(git.absolute())], cwd=root, env=env, capture_output=True, text=True)
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: Settings sheet case completed' not in result.stdout:
                raise SystemExit('Settings receiver exited before completion: '+case)
