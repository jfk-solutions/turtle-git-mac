#!/usr/bin/env python3
"""Audit runtime architecture/dependencies and exercise real local Git operations."""
import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import tempfile

MACH = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('runtime', type=pathlib.Path)
    parser.add_argument('--https', action='store_true', help='Also verify a public HTTPS ls-remote with no user Git configuration.')
    args = parser.parse_args(); runtime = args.runtime.resolve()
    manifest = json.loads((runtime / 'runtime-manifest.json').read_text())
    source = runtime / 'share/licenses/git' / ('git-' + manifest['version'] + '.tar.xz')
    assert hashlib.sha256(source.read_bytes()).hexdigest() == manifest['source_sha256']
    assert (source.parent / 'COPYING').is_file()
    assert (source.parent / 'SHA1DC-LICENSE.txt').is_file()
    assert (source.parent / 'REFTable-LICENSE').is_file()
    assert (source.parent / 'build/scripts/build-git-runtime.py').is_file()
    for required in ['bin/git', 'libexec/git-core/git-remote-https', 'libexec/git-core/git-credential-osxkeychain', 'share/git-core/templates']:
        assert (runtime / required).exists(), required
    binaries = 0
    for path in runtime.rglob('*'):
        if path.is_symlink():
            assert path.resolve().is_relative_to(runtime), 'Escaping runtime symlink: ' + str(path)
        elif path.is_file() and path.open('rb').read(4) in MACH:
            binaries += 1
            architectures = subprocess.check_output(['/usr/bin/lipo', '-archs', str(path)], text=True).split()
            assert set(architectures) == set(manifest['architectures']), str(path)
            commands = subprocess.check_output(['/usr/bin/otool', '-l', str(path)], text=True)
            minimums = [line.split()[1] for line in commands.splitlines() if line.strip().startswith('minos ')]
            assert len(minimums) == len(architectures), 'Missing deployment target: ' + str(path)
            target = tuple(int(part) for part in manifest['minimum_macos'].split('.'))
            assert all(tuple(int(part) for part in version.split('.')) <= target for version in minimums), str(path)
            links = subprocess.check_output(['/usr/bin/otool', '-L', str(path)], text=True)
            for line in links.splitlines():
                if '(compatibility version' in line:
                    library = line.strip().split(' (')[0]
                    assert library.startswith(('/usr/lib/', '/System/Library/')), library
    environment = dict({key: value for key, value in os.environ.items() if not key.startswith('GIT_')}, GIT_EXEC_PATH=str(runtime / 'libexec/git-core'),
                       GIT_TEMPLATE_DIR=str(runtime / 'share/git-core/templates'),
                       PATH=str(runtime / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin',
                       GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_TERMINAL_PROMPT='0')
    git = runtime / 'bin/git'
    def run(*arguments, **kwargs):
        return subprocess.check_output([str(git), *arguments], env=environment, stderr=subprocess.STDOUT, **kwargs)
    assert run('--version').strip() == ('git version ' + manifest['version']).encode()
    with tempfile.TemporaryDirectory(prefix='turtlegit-runtime-smoke-') as temporary:
        repository = pathlib.Path(temporary) / 'repo'; repository.mkdir()
        run('-C', str(repository), 'init', '-b', 'main')
        run('-C', str(repository), 'config', 'user.name', 'Runtime QA')
        run('-C', str(repository), 'config', 'user.email', 'runtime@example.invalid')
        path = repository / 'file 雪.txt'; path.write_bytes(b'base\n')
        encoded_files = {}
        for encoding, bom in [('utf-16-le', b'\xff\xfe'), ('utf-16-be', b'\xfe\xff')]:
            for with_bom in [False, True]:
                name = f'{encoding}-{with_bom}.txt'
                encoded_files[name] = (bom if with_bom else b'') + 'first\r\n雪 turtle\r\n\r\n'.encode(encoding)
                (repository / name).write_bytes(encoded_files[name])
        for encoding, text in [('cp1252', 'Preis € – café\r\n'), ('cp850', 'dsöd\n\n'), ('cp932', '日本語\n東京\n')]:
            name = encoding + '.txt'; encoded_files[name] = text.encode(encoding)
            (repository / name).write_bytes(encoded_files[name])
        run('-C', str(repository), 'add', '--', path.name, *encoded_files)
        run('-C', str(repository), '-c', 'commit.gpgsign=false', 'commit', '-m', 'base')
        path.write_bytes(b'working\n')
        head = run('-C', str(repository), 'rev-parse', 'HEAD').strip()
        index = (repository / '.git/index').read_bytes()
        annotation = run('--literal-pathspecs', '-C', str(repository), '-c', 'blame.blankBoundary=false',
                         'blame', '--line-porcelain', '--no-progress', '--no-textconv', '-w', '-M', '-C',
                         head.decode('ascii'), '--', path.name)
        assert annotation.startswith(head + b' 1 1 1\n')
        assert b'\nauthor Runtime QA\n' in annotation and b'\nauthor-mail <runtime@example.invalid>\n' in annotation
        assert annotation.endswith(b'\tbase\n'), 'Historical blame must ignore uncommitted contents'
        assert (repository / '.git/index').read_bytes() == index and path.read_bytes() == b'working\n'
        for name, original in encoded_files.items():
            encoded_annotation = run('--literal-pathspecs', '-C', str(repository), 'blame',
                                     '--line-porcelain', '--no-progress', '--no-textconv',
                                     head.decode('ascii'), '--', name)
            payloads = [record[1:] for record in encoded_annotation.split(b'\n') if record.startswith(b'\t')]
            expected = original.split(b'\n')
            if original.endswith(b'\n'): expected.pop()
            assert payloads == expected, f'Encoded source byte framing mismatch: {name}'
            assert (repository / name).read_bytes() == original
        assert (repository / '.git/index').read_bytes() == index
        assert run('-C', str(repository), 'rev-parse', 'HEAD').strip() == head
        assert b'+working' in run('-C', str(repository), 'diff', '--', path.name)
        run('-C', str(repository), 'stash', 'push', '-m', 'runtime stash')
        assert path.read_bytes() == b'base\n'
        run('-C', str(repository), 'stash', 'pop')
        assert path.read_bytes() == b'working\n'
        clone = pathlib.Path(temporary) / 'clone'
        run('clone', '--no-local', str(repository), str(clone))
        assert (clone / path.name).read_bytes() == b'base\n'
        assert b'base' in run('-C', str(clone), 'log', '-1', '--format=%s')
        merge_repo = pathlib.Path(temporary) / 'first-parent'; merge_repo.mkdir()
        def merge_run(*arguments): return run('--literal-pathspecs', '-C', str(merge_repo), *arguments)
        merge_run('init', '-b', 'main'); merge_run('config', 'user.name', 'Runtime QA'); merge_run('config', 'user.email', 'runtime@example.invalid')
        merge_file = merge_repo / 'source 雪.txt'; base = b'main base\nspacer\nside base\n'
        def commit_text(text, message):
            merge_file.write_bytes(text); merge_run('add', '--', merge_file.name)
            merge_run('-c', 'commit.gpgsign=false', 'commit', '-m', message)
            return merge_run('rev-parse', 'HEAD').strip()
        origin = commit_text(base, 'base')
        merge_run('checkout', '-b', 'side'); side = commit_text(base.replace(b'side base', b'side change'), 'side')
        merge_run('checkout', 'main'); main_hash = commit_text(base.replace(b'main base', b'main change'), 'main')
        merge_run('-c', 'commit.gpgsign=false', 'merge', '--no-ff', 'side', '-m', 'integrate side')
        merge_hash = merge_run('rev-parse', 'HEAD').strip(); merge_index = (merge_repo / '.git/index').read_bytes()
        merge_file.write_bytes(b'working replacement\n')
        def hashes(*options):
            raw = merge_run('blame', '--line-porcelain', '--no-textconv', *options, merge_hash.decode('ascii'), '--', merge_file.name)
            return [line.split()[0] for line in raw.splitlines() if re.fullmatch(rb'[0-9a-f]{40,64} [0-9]+ [0-9]+(?: [0-9]+)?', line)]
        assert hashes() == [main_hash, origin, side]
        assert hashes('--first-parent') == [main_hash, origin, merge_hash]
        assert (merge_repo / '.git/index').read_bytes() == merge_index and merge_file.read_bytes() == b'working replacement\n'
        assert merge_run('rev-parse', 'HEAD').strip() == merge_hash
    if args.https:
        with tempfile.TemporaryDirectory(prefix='turtlegit-runtime-https-') as directory:
            result = run('ls-remote', '--exit-code', 'https://github.com/TortoiseGit/TortoiseGit.git', 'HEAD', timeout=60, cwd=directory)
        assert result.rstrip().endswith(b'\tHEAD'), 'Missing HTTPS remote HEAD'
        print('Public HTTPS ls-remote passed with bundled git-remote-https.')
    print(f'Git {manifest["version"]}: {binaries} Mach-O files audited; architectures {manifest["architectures"]}; local init/commit/diff/stash/clone/log/blame (UTF-8, UTF-16, legacy code pages and first-parent merge attribution) passed.')

if __name__ == '__main__': main()
