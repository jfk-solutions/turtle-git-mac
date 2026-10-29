#!/usr/bin/env python3
"""Grouped standalone Merge command entry and native editor families."""
import argparse
import json
import os
from pathlib import Path
import tempfile
import time
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['comparison', 'three-file', 'launch', 'blame', 'continuity', 'scene', 'reflected'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='tg-merge-tool-entry-') as temporary:
    folder = Path(temporary)
    if not args.only:
        helper = folder/'fake app executable'
        arguments = folder/'arguments.json'
        helper.write_text('#!/usr/bin/env python3\nimport json,os,sys,time\nfrom pathlib import Path\nPath(os.environ["TURTLEGIT_WRAPPER_ARGUMENTS"]).write_text(json.dumps(sys.argv[1:]))\ntime.sleep(0.2)\nsys.exit(17)\n')
        helper.chmod(0o700)
        env = dict(os.environ, TURTLEGIT_MERGE_EXECUTABLE=str(helper), TURTLEGIT_WRAPPER_ARGUMENTS=str(arguments))
        literal = ['--base', str(folder/'base [literal]\nfile'), '--mine', str(folder/'mine file')]
        start = time.monotonic()
        result = run_receiver([str(root/'scripts/turtlegit-merge'), *literal], cwd=root, env=env, capture_output=True, text=True)
        assert result.returncode == 17 and time.monotonic()-start >= 0.2
        assert json.loads(arguments.read_text()) == ['--merge-tool', *literal]
        print('PASS: waiting wrapper preserves literal arguments and exact child exit status', flush=True)
    sources = [root/'docs/qa'/name for name in ['merge-tool-comparison-native-2026-10-18.swift', 'merge-tool-three-file-native-2026-10-18.swift', 'merge-tool-launch-native-2026-10-18.swift', 'merge-blame-native-2026-10-18.swift', 'merge-tool-continuity-native-2026-10-18.swift', 'merge-tool-scene-native-2026-10-18.swift', 'merge-reflected-patch-native-2026-10-18.swift']]
    main = folder/'MergeToolMain.swift'
    main.write_text('''import AppKit
@main struct MergeToolMain {
 @MainActor static func main() async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  switch ProcessInfo.processInfo.environment["TURTLEGIT_MERGE_ENTRY_CASE"]! {
   case "comparison": try await TwoFileMergeToolVerification.verify()
   case "three-file": try await ThreeFileMergeToolVerification.verify()
   case "launch": try await MergeToolLaunchVerification.verify()
   case "blame": try await MergeBlameVerification.verify()
   case "continuity": try await MergeToolContinuityVerification.verify()
   case "scene": try await MergeToolSceneVerification.verify()
   case "reflected": try await MergeReflectedPatchVerification.verify()
   default: fatalError("Unknown Merge entry case")
  }
  print("PASS: Merge entry family case completed")
 }
}
''')
    receiver = build_receiver(root, sources+[main], folder)
    base_environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    base_environment.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for case in args.only or ['comparison', 'three-file', 'launch', 'blame', 'continuity', 'scene', 'reflected']:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            fixture = folder/(case+str(index)); fixture.mkdir()
            child_root = folder/(case+str(index)+'-environment'); child_root.mkdir(mode=0o700)
            private_home = child_root/'home'; private_home.mkdir(mode=0o700)
            private_tmp = child_root/'temporary'; private_tmp.mkdir(mode=0o700)
            private_xdg = child_root/'xdg'; private_xdg.mkdir(mode=0o700)
            (private_home/'Library/Preferences').mkdir(parents=True, mode=0o700)
            env = dict(base_environment, HOME=str(private_home), CFFIXED_USER_HOME=str(private_home),
                       TMPDIR=str(private_tmp)+'/', XDG_CONFIG_HOME=str(private_xdg),
                       TURTLEGIT_MERGE_ENTRY_CASE=case)
            print('Checking Merge tool '+case+' with '+str(git), flush=True)
            result = run_receiver([str(receiver), str(fixture), str(git.absolute())], cwd=root, env=env, capture_output=True, text=True)
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS: Merge entry family case completed' not in result.stdout:
                raise SystemExit('Merge entry receiver exited before completion: '+case)
