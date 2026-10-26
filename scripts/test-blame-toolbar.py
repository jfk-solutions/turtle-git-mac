#!/usr/bin/env python3
"""Grouped private native Blame toolbar/customization and lifetime workflows."""
import argparse
import hashlib
import os
from pathlib import Path
import tempfile
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=('composition', 'placement'), action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
cases = {
    'composition': ('blame-toolbar-native-2026-10-26.swift', 'PASS Blame toolbar:'),
    'placement': ('blame-toolbar-placement-native-2026-10-26.swift', 'PASS Blame toolbar placement:'),
}
receivers = {}
for name in args.only or cases:
    sources = root/('build/qa/blame-toolbar-' + name + '-native-sources')
    sources.mkdir(parents=True, exist_ok=True)
    receivers[name] = build_receiver(root, [root/'docs/qa'/cases[name][0]], sources)
with tempfile.TemporaryDirectory(prefix='turtlegit-blame-toolbar-native-') as temporary:
    folder = Path(temporary)
    environment = {key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
    environment.update(DYLD_FRAMEWORK_PATH=str(root/'build/Build/Products/Debug'), GIT_CONFIG_GLOBAL=os.devnull,
                       GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
    for index, (name, git) in enumerate((name, git) for name in receivers for git in (args.git or [Path('/usr/bin/git')])):
        fixture = folder/str(index); fixture.mkdir()
        home = fixture/'home'; home.mkdir(mode=0o700)
        private_temporary = fixture/'temporary'; private_temporary.mkdir(mode=0o700)
        repository = fixture/'repository'; repository.mkdir()
        environment.update(CFFIXED_USER_HOME=str(home), TMPDIR=str(private_temporary)+'/', XDG_CONFIG_HOME=str(fixture/'xdg'))
        print('Checking private native Blame toolbar '+name+' with '+str(git), flush=True)
        receiver = receivers[name]
        command = [str(receiver), str(repository), str(git.absolute())]
        if name == 'placement':
            captures = root/'build/qa/blame-toolbar-placement-captures'/hashlib.sha256(str(git.absolute()).encode()).hexdigest()[:10]
            captures.mkdir(parents=True, exist_ok=True)
            command.append(str(captures))
        result = run_receiver(command, cwd=root, env=environment,
                              capture_output=True, text=True, timeout_sample=fixture/'timeout.sample.txt')
        print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
        if cases[name][1] not in result.stdout:
            raise SystemExit('Blame toolbar receiver exited before its final assertion')
