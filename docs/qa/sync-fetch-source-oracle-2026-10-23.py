#!/usr/bin/env python3
"""Reproduce the local source call-order oracle without building app/Core/helper."""
import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, default=Path('/usr/bin/git'))
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
pin = json.loads((root / 'Configuration/LibGit2Runtime.json').read_text())['libgit2']['commit']
cache = root / 'build/libgit2-runtime/cache'
architect = platform.machine()
components = []
for receipt in sorted(cache.glob('native-*/native-provenance.json')):
    metadata = json.loads(receipt.read_text())
    library = receipt.parent / architect / 'libgit2.a'
    if metadata.get('inputs', {}).get('pin', {}).get('libgit2', {}).get('commit') == pin and library.is_file():
        components.append((receipt.parent / 'source/include', library))
if not components:
    raise SystemExit('Existing pinned native static slice required; this oracle never rebuilds it.')
headers, library = components[0]
with tempfile.TemporaryDirectory(prefix='sync-source-oracle-') as directory:
    folder = Path(directory)
    global_config = folder / 'global.config'
    global_config.write_text('')
    environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    environment.update(GIT_CONFIG_GLOBAL=str(global_config), GIT_CONFIG_NOSYSTEM='1')
    executable = folder / 'oracle'
    subprocess.run(['xcrun', 'clang', '-I', str(headers), str(Path(__file__).with_suffix('.c')),
                    str(library), '-framework', 'Security', '-framework', 'CoreFoundation',
                    '-lz', '-liconv', '-lresolv', '-o', str(executable)], check=True, env=environment, timeout=60)

    def git(*arguments, cwd=None):
        return subprocess.check_output([str(args.git.resolve()), *arguments], cwd=cwd, env=environment,
                                       stderr=subprocess.DEVNULL, text=True, timeout=30).strip()

    author, server, client = folder / 'author', folder / 'server.git', folder / 'client'
    git('init', '--template=', '-b', 'main', str(author))
    for key, value in [('user.name', 'Source oracle QA'), ('user.email', 'oracle@example.invalid'),
                       ('commit.gpgsign', 'false'), ('core.hooksPath', '/dev/null')]:
        git('config', key, value, cwd=author)
    (author / 'file').write_text('base\n')
    git('add', 'file', cwd=author)
    git('commit', '-m', 'base', cwd=author)
    git('clone', '--template=', '--bare', '--', str(author), str(server))
    git('clone', '--template=', '--', str(server), str(client))
    for spec in ['refs/heads/main:refs/remotes/origin/main',
                 'refs/heads/does-not-exist:refs/remotes/origin/does-not-exist']:
        result = subprocess.run([str(executable), str(client), spec], cwd=client, env=environment,
                                capture_output=True, text=True, timeout=30)
        print('REQUEST', spec, 'CODE', result.returncode)
        print(result.stdout, end='')
        print(result.stderr, end='')
        print('CONFIG AFTER', git('config', '--get-all', 'remote.origin.fetch', cwd=client))
        result.check_returncode()
