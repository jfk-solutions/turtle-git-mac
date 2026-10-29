#!/usr/bin/env python3
"""Private native standalone ImageTool choice, output and scoped resolution workflow."""
import argparse
import os
from pathlib import Path
import shutil
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['launches'], help='Focused launch ownership diagnostic; default runs the complete workflow')
parser.add_argument('--screenshots', type=Path, help='Write offscreen native content-only light/dark captures for the first Git engine')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
sources = root/'build/qa/image-tool-selection-native-sources'
sources.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [root/'docs/qa/image-tool-selection-native-2026-10-29.swift'], sources)
for index, git in enumerate(args.git or [Path('/usr/bin/git'), root/'build/git-runtime/Git/bin/git']):
    with tempfile.TemporaryDirectory(prefix='turtlegit-image-tool-selection-') as temporary:
        folder = Path(temporary)
        for name in ['repository', 'home', 'temporary', 'xdg']:
            (folder/name).mkdir(mode=0o700)
        (folder/'home/Library/Preferences').mkdir(parents=True, mode=0o700)
        environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        environment.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'),
                           GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0', GIT_OPTIONAL_LOCKS='0',
                           HOME=str(folder/'home'), CFFIXED_USER_HOME=str(folder/'home'),
                           TMPDIR=str(folder/'temporary')+'/', XDG_CONFIG_HOME=str(folder/'xdg'))
        environment.pop('TURTLEGIT_IMAGE_SELECTION_CAPTURE', None)
        environment.pop('TURTLEGIT_IMAGE_SELECTION_ONLY', None)
        if args.only is not None:
            environment['TURTLEGIT_IMAGE_SELECTION_ONLY'] = args.only
        if args.screenshots is not None and index == 0:
            captures = args.screenshots.expanduser().resolve()
            captures.mkdir(parents=True, exist_ok=True)
            environment['TURTLEGIT_IMAGE_SELECTION_CAPTURE'] = str(captures)
        print('Checking private ImageTool selection with '+str(git), flush=True)
        try:
            result = run_receiver([str(receiver), str(folder/'repository'), str(git.absolute()), str(root/'Tests/TurtleGitCoreTests/Fixtures/Metafile')],
                                  cwd=root, env=environment, capture_output=True, text=True, timeout=180,
                                  timeout_sample=folder/'timeout.sample.txt')
            print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
            if 'PASS standalone ImageTool selection:' not in result.stdout:
                raise RuntimeError('ImageTool selection receiver exited before final assertions/cleanup')
        except BaseException:
            evidence = Path(tempfile.mkdtemp(prefix='image-tool-selection-failed-'+str(index)+'-', dir=root/'build/qa'))
            shutil.copytree(folder, evidence, dirs_exist_ok=True)
            print('Private failed fixture evidence: '+str(evidence), flush=True)
            raise
