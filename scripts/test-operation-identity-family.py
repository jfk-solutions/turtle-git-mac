#!/usr/bin/env python3
"""Grouped exact-name operations, native metadata, Retry and result-log consumers."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
from native_receiver import build_receiver, run_receiver


def retire_owned_helpers(private, approved):
    """Require a private resource plus an approved Git/test-shell image."""
    def owned():
        listing = subprocess.run(['/usr/sbin/lsof', '-t', '+D', str(private)], capture_output=True, text=True, timeout=10)
        if listing.returncode not in (0, 1):
            raise RuntimeError('Cannot inspect private operation-helper ownership')
        result = []
        for value in set(listing.stdout.split()):
            pid = int(value)
            images = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'txt', '-Fn'], capture_output=True, text=True, timeout=5)
            names = {str(Path(line[1:]).resolve()) for line in images.stdout.splitlines() if line.startswith('n')}
            if names.intersection(approved):
                result.append(pid)
        return result
    remaining = owned(); needed = bool(remaining)
    for action in [signal.SIGTERM, signal.SIGKILL]:
        for pid in remaining:
            if pid not in owned():
                continue
            try:
                os.killpg(pid, action) if os.getpgid(pid) == pid else os.kill(pid, action)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            remaining = owned()
            if not remaining:
                return needed
            time.sleep(.03)
    raise RuntimeError('Owned operation helper survived cleanup: ' + str(remaining))

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
cases = {
    'revert-exact': ('operation-exact-retry-native-2026-11-05.swift', [], 'PASS: exact-name Revert'),
    'metadata': ('reference-refresh-native-2026-10-24.swift', ['metadata'], 'PASS: reference refresh metadata'),
    'lifetime': ('reference-refresh-native-2026-10-24.swift', ['lifetime'], 'PASS: reference refresh lifetime'),
    'preparation': ('transport-preparation-native-2026-10-14.swift', [], 'PASS: Transport preparation snapshot/cancel/retry/source replacement'),
    'progress': ('progress-diagnostic-native-2026-10-17.swift', [], 'PASS: prefixed command diagnostics'),
    'action-log': ('action-log-native-2026-10-08.swift', [], 'PASS: native close/quiet output/Retry retention'),
}
parser.add_argument('--only', choices=list(cases), action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
results, receivers = [], {}
for case in args.only or cases:
    filename, arguments, marker = cases[case]
    if filename not in receivers:
        cache = root / 'build/qa/operation-identity-sources' / Path(filename).stem
        cache.mkdir(parents=True, exist_ok=True)
        receivers[filename] = build_receiver(root, [root / 'docs/qa' / filename], cache)
    for git in args.git or [Path('/usr/bin/git'), root / 'build/git-runtime/Git/bin/git']:
        with tempfile.TemporaryDirectory(prefix='turtlegit-operation-identity-') as directory:
            private = Path(directory)
            env = {k: v for k, v in os.environ.items() if not k.startswith(('GIT_', 'TURTLEGIT_'))}
            for name, key in [('home', 'HOME'), ('preferences', 'CFFIXED_USER_HOME'), ('xdg', 'XDG_CONFIG_HOME'), ('temporary', 'TMPDIR')]:
                path = private / name; path.mkdir(mode=0o700)
                env[key] = str(path) + ('/' if key == 'TMPDIR' else '')
            config = private / 'global.config'; config.write_text('')
            env.update(DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'),
                       GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
            fixture = private / 'fixture'; fixture.mkdir(mode=0o700)
            print('Checking operation identity ' + case + ' with ' + str(git), flush=True)
            approved = {str(path.resolve()) for path in [git, Path('/bin/sh'), Path('/bin/sleep')]}
            for helper in [root / 'build/libgit2-runtime/LibGit2/bin/turtlegit-libgit2',
                           root / 'build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/LibGit2/bin/turtlegit-libgit2']:
                if helper.is_file():
                    approved.add(str(helper.resolve()))
            system_git = subprocess.run(['/usr/bin/xcrun', '--find', 'git'], capture_output=True, text=True)
            if system_git.returncode == 0:
                approved.add(str(Path(system_git.stdout.strip()).resolve()))
            passed = False
            try:
                result = run_receiver([str(receivers[filename]), str(fixture), str(git.absolute()), *arguments],
                                      cwd=root, env=env, capture_output=True, text=True,
                                      timeout_sample=root / ('build/qa/operation-identity-' + case + '.sample.txt'))
                print(result.stdout, end=''); print(result.stderr, end='')
                passed = result.returncode == 0 and marker in result.stdout
                results.append(dict(case=case, git=str(git.absolute()), returncode=result.returncode, passed=passed))
                (root / 'build/qa/operation-identity-results.json').write_text(json.dumps(results, indent=2) + '\n')
                result.check_returncode()
                if not passed:
                    raise RuntimeError('Native operation receiver exited before its final assertions: ' + case)
            finally:
                if retire_owned_helpers(private, approved) and passed:
                    results[-1].update(passed=False, helper_cleanup_needed=True)
                    (root / 'build/qa/operation-identity-results.json').write_text(json.dumps(results, indent=2) + '\n')
                    raise RuntimeError('Successful operation receiver left an owned helper running')
