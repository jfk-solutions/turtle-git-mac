#!/usr/bin/env python3
"""Focused actual Commit presentation and owner-specific Log context-menu icons."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
from native_receiver import build_receiver, run_receiver

def retire_owned_git(context, images):
    """Require both an exact Git executable and an open private fixture path."""
    def owned():
        result = subprocess.run(['/usr/sbin/lsof', '-t', '+D', str(context)],
                                capture_output=True, text=True, timeout=10)
        if result.returncode not in (0, 1):
            raise RuntimeError('Cannot inspect private primary-dialog helper ownership')
        matches = []
        for value in set(result.stdout.split()):
            pid = int(value)
            image = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'txt', '-Fn'],
                                   capture_output=True, text=True, timeout=5)
            paths = {str(Path(line[1:]).resolve()) for line in image.stdout.splitlines() if line.startswith('n')}
            if paths.intersection(images):
                matches.append(pid)
        return matches
    needed = bool(owned())
    for number in (signal.SIGTERM, signal.SIGKILL):
        for pid in owned():
            if pid not in owned():
                continue
            try:
                group = os.getpgid(pid)
                os.killpg(group, number) if group == pid else os.kill(pid, number)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 3
        while owned() and time.monotonic() < deadline:
            time.sleep(.03)
        if not owned():
            return needed
    raise RuntimeError('Verified private Git helper survived primary-dialog cleanup')


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['commit', 'log'], action='append')
parser.add_argument('--visual-acceptance-dir', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
generated = root / 'build/qa/primary-presentation-corrections-native-sources'
generated.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [root / 'docs/qa/primary-presentation-corrections-native-2026-10-23.swift'], generated)
engines = args.git or [Path('/usr/bin/git')]
system_git = subprocess.check_output(['/usr/bin/xcrun', '--find', 'git'], text=True).strip()
images = {str(path.resolve()) for path in [*engines, Path(system_git), root / 'build/git-runtime/Git/bin/git'] if path.is_file()}
with tempfile.TemporaryDirectory(prefix='turtlegit-primary-corrections-') as temporary:
    for case in args.only or ['commit', 'log']:
        for index, git in enumerate(engines):
            context = Path(temporary) / (case + str(index)); context.mkdir(mode=0o700)
            paths = {name: context / name for name in ['fixture', 'home', 'temporary', 'xdg']}
            for path in paths.values():
                path.mkdir(mode=0o700)
            config = context / 'global.config'; config.write_text('')
            env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            env.update(DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'),
                       GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                       HOME=str(paths['home']), CFFIXED_USER_HOME=str(paths['home']),
                       XDG_CONFIG_HOME=str(paths['xdg']), TMPDIR=str(paths['temporary'])+'/')
            env.pop('TURTLEGIT_PRIMARY_VISUAL_ACCEPTANCE', None)
            if args.visual_acceptance_dir and case == 'commit' and index == 0 and git.absolute() == Path('/usr/bin/git'):
                args.visual_acceptance_dir.resolve().mkdir(parents=True, exist_ok=True)
                env['TURTLEGIT_PRIMARY_VISUAL_ACCEPTANCE'] = str(args.visual_acceptance_dir.resolve())
            print('Checking primary presentation '+case+' with '+str(git), flush=True)
            completed = False
            try:
                result = run_receiver([str(receiver), str(paths['fixture']), str(git.absolute()), case],
                                      cwd=root, env=env, capture_output=True, text=True,
                                      timeout_sample=root / ('build/qa/primary-presentation-'+case+'-'+str(index)+'.sample.txt'))
                print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
                if 'PASS: primary presentation corrections '+case not in result.stdout:
                    raise SystemExit('Primary presentation receiver exited before completion')
                completed = True
            finally:
                needed = retire_owned_git(context, images)
                if completed and needed:
                    raise RuntimeError('Successful presentation case left owned Git work running')
