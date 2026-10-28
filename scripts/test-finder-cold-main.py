#!/usr/bin/env python3
"""Private production outer main and real SwiftUI App.main receipt launch; no URL registration or installed app."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
generated = root / 'build/qa/finder-cold-main-native-sources'
generated.mkdir(parents=True, exist_ok=True)
receiver = build_receiver(root, [root / 'docs/qa/finder-actual-main-native-2026-10-28.swift'], generated)
results = []
for git in args.git or [Path('/usr/bin/git'), root / 'build/git-runtime/Git/bin/git']:
    git = git.absolute()
    with tempfile.TemporaryDirectory(prefix='turtlegit-cold-main-') as temporary:
        context = Path(temporary).resolve()
        for name in ('preferences', 'home', 'temporary', 'xdg', 'fixture'):
            (context / name).mkdir(mode=0o700)
        repository = context / 'fixture/repository'
        repository.mkdir(mode=0o700)
        config = context / 'global.config'
        config.write_text('')
        env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        env.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                   HOME=str(context / 'home'), CFFIXED_USER_HOME=str(context / 'preferences'),
                   XDG_CONFIG_HOME=str(context / 'xdg'), TMPDIR=str(context / 'temporary') + '/',
                   DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'),
                   TURTLEGIT_QA_REPOSITORY=str(repository), TURTLEGIT_QA_GIT=str(git),
                   TURTLEGIT_QA_HANDOFFS=str(context / 'fixture/action-handoffs'),
                   TURTLEGIT_QA_ARCHIVE=str(context / 'fixture/access.json'))
        def command(*arguments):
            subprocess.run([str(git), '-C', str(repository), *arguments], env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=20)
        command('init', '--template=', '-b', 'main')
        for key, value in [('user.name', 'Actual Cold QA'), ('user.email', 'cold@example.invalid'),
                           ('commit.gpgsign', 'false'), ('core.hooksPath', '/dev/null')]:
            command('config', key, value)
        (repository / 'tracked.txt').write_bytes(b'before\n')
        command('add', '--', 'tracked.txt')
        command('commit', '-m', 'initial')
        (repository / 'tracked.txt').write_bytes(b'after\n')
        app = context / 'Private Cold Startup QA.app'
        executable = app / 'Contents/MacOS/ColdStartupQA'
        executable.parent.mkdir(parents=True)
        shutil.copy2(receiver, executable)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
            CFBundleIdentifier='org.turtlegit.qa.cold.' + uuid.uuid4().hex,
            CFBundleName='Private Cold Startup QA', CFBundleExecutable='ColdStartupQA',
            CFBundlePackageType='APPL', NSPrincipalClass='NSApplication',
            LSMinimumSystemVersion='13.0', LSUIElement=True)))
        print('Checking actual SwiftUI cold main with ' + str(git), flush=True)
        producer = run_receiver([str(executable)], cwd=root, env=dict(env, TURTLEGIT_QA_PUBLISH='1'),
                                capture_output=True, text=True, timeout=30)
        print(producer.stdout, end=''); print(producer.stderr, end='')
        producer.check_returncode()
        capabilities = [line[len('COLD_CAPABILITY '):] for line in producer.stdout.splitlines()
                        if line.startswith('COLD_CAPABILITY ')]
        if len(capabilities) != 1:
            raise RuntimeError('Private native producer did not publish one receipt')
        result = run_receiver([str(executable), '--turtlegit-finder-request', capabilities[0]],
                              cwd=root, env=env, capture_output=True, text=True, timeout=35,
                              timeout_sample=context / 'timeout.sample.txt')
        print(result.stdout, end=''); print(result.stderr, end='')
        samples = [json.loads(line[len('COLD_MAIN_TIMING '):]) for line in result.stdout.splitlines()
                   if line.startswith('COLD_MAIN_TIMING ')]
        passed = result.returncode == 0 and 'PASS: actual SwiftUI cold Finder Commit main' in result.stdout
        results.append(dict(git=str(git), returncode=result.returncode, passed=passed, samples=samples,
                            scope='Private production TurtleGitApplication.main and real SwiftUI process with native receipt argv and own raw events; not physical Finder/NSWorkspace or signed distribution.'))
        (root / 'build/qa/finder-cold-main-native-results.json').write_text(json.dumps(results, indent=2) + '\n')
        result.check_returncode()
        if not passed or len(samples) != 1:
            raise RuntimeError('Actual cold startup receiver did not complete its bounded checks')
