#!/usr/bin/env python3
"""Grouped reflected EditorConfig, Log reference and external workspace workflows."""
import argparse
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['editorconfig', 'references', 'handoff'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-metadata-port-') as temporary:
    folder = Path(temporary)
    sources = [root/'docs/qa'/name for name in ['editorconfig-reflected-native-2026-10-18.swift', 'log-reference-interaction-native-2026-10-18.swift', 'workspace-open-handoff-native-2026-10-18.swift']]
    main = folder/'MetadataPortMain.swift'
    main.write_text('''import AppKit
@main struct MetadataPortMain {
 @MainActor static func main() async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  switch ProcessInfo.processInfo.environment["TURTLEGIT_METADATA_PORT_CASE"]! {
   case "editorconfig": try await EditorConfigReflectedVerification.verify()
   case "references": try await LogReferenceInteractionVerification.verify()
   case "handoff": try await WorkspaceOpenHandoffVerification.verify()
   default: fatalError("Unknown metadata port case")
  }
  print("PASS: Metadata port family case completed")
 }
}
''')
    receiver = build_receiver(root, sources+[main], folder)
    env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for case in args.only or ['editorconfig', 'references', 'handoff']:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture = folder/(case+str(index)); fixture.mkdir()
            env['TURTLEGIT_METADATA_PORT_CASE'] = case
            print('Checking metadata port '+case+' with '+str(git), flush=True)
            result = run_receiver([str(receiver), str(fixture), str(git.absolute())], cwd=root, env=env, capture_output=True, text=True)
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: Metadata port family case completed' not in result.stdout:
                raise SystemExit('Metadata port receiver exited before completion: '+case)
