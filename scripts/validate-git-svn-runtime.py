#!/usr/bin/env python3
"""Audit the private SVN payload and exercise git-svn only on a disposable local repository."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid
import sys
from validate_git_svn_support import deployment

ROOT = Path(__file__).resolve().parents[1]
MACH = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}

def audit(runtime, manifest, installed=False):
    assert manifest['pin'] == json.loads((ROOT / 'Configuration/GitSVNRuntime.json').read_text()), 'SVN source pins differ'
    assert manifest['git'] == json.loads((ROOT / 'Configuration/GitRuntime.json').read_text()), 'Git source pins differ'
    assert manifest['architectures'] and set(manifest['architectures']) <= {'arm64', 'x86_64'}, 'Invalid architecture list'
    for relative, expected in manifest['files_sha256'].items():
        path = runtime / relative
        assert path.is_file() and not path.is_symlink(), relative
        assert hashlib.sha256(path.read_bytes()).hexdigest() == expected, relative
    actual = {str(p.relative_to(runtime)) for p in runtime.rglob('*') if p.is_file() and not p.is_symlink()}
    if installed:
        actual = {x for x in actual if x.startswith(('libexec/git-svn-runtime/', 'share/licenses/git-svn/')) or x == 'libexec/git-core/git-svn'}
        actual.discard('share/licenses/git-svn/runtime-manifest.json')
    else: actual.discard('runtime-manifest.json')
    assert actual == set(manifest['files_sha256']), 'Unexpected runtime files'
    payload = runtime / 'libexec/git-svn-runtime'
    binaries = 0
    for path in runtime.rglob('*'):
        if installed and not (path.is_relative_to(payload) or path == runtime / 'libexec/git-core/git-svn'): continue
        if path.is_symlink(): assert path.resolve().is_relative_to(runtime), str(path)
        elif path.is_file() and path.open('rb').read(4) in MACH:
            binaries += 1
            relative = path.relative_to(payload) if path.is_relative_to(payload) else None
            architectures = [relative.parts[0]] if relative else manifest['architectures']
            deployment(path, architectures, manifest['pin']['minimum_macos'])
            for line in subprocess.check_output(['/usr/bin/otool', '-L', path], text=True).splitlines()[1:]:
                if '(compatibility version' not in line: continue
                library = line.strip().split(' (', 1)[0]
                if library.startswith(('/usr/lib/', '/System/Library/')): continue
                if library.startswith('@rpath/'):
                    assert path.suffix == '.dylib' and library == '@rpath/' + path.name, library
                else:
                    assert library.startswith('@loader_path/'), library
                    target = (path.parent / library[len('@loader_path/'):]).resolve()
                    assert target.is_file() and target.is_relative_to(runtime), library
                    if relative: assert target.is_relative_to(payload / relative.parts[0]), 'Cross-architecture dependency'
    for arch in manifest['architectures']:
        root = payload / arch
        for name in ['Perl/bin/perl', 'Subversion/bin/svn', 'Subversion/bin/svnadmin', 'GitPerl/git-svn.perl', 'GitPerl/Git/SVN.pm']:
            assert (root / name).is_file(), name
    print('Git SVN native dependencies, deployment targets, payload hashes and contained aliases verified:', binaries)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('runtime', type=Path)
    parser.add_argument('--git', type=Path, default=ROOT / 'build/git-runtime/Git/bin/git')
    parser.add_argument('--audit-only', action='store_true')
    parser.add_argument('--installed', action='store_true')
    args = parser.parse_args(); runtime = args.runtime.resolve()
    manifest_path = runtime / ('share/licenses/git-svn/runtime-manifest.json' if args.installed else 'runtime-manifest.json')
    manifest = json.loads(manifest_path.read_text())
    audit(runtime, manifest, installed=args.installed)
    if args.audit_only: return
    with no_build_fallbacks(manifest): exercise(args, runtime, manifest)

@contextmanager
def no_build_fallbacks(manifest):
    identity = hashlib.sha256(json.dumps(manifest['buildInputs'], sort_keys=True).encode()).hexdigest()
    directory = ROOT / 'build/git-svn-runtime/work' / identity
    hidden = []
    try:
        for arch in manifest['architectures']:
            original = directory / arch / 'prefix'
            if original.is_dir():
                backup = original.with_name('prefix.validation-hidden-' + str(uuid.uuid4()))
                original.replace(backup); hidden.append((original, backup))
        yield
    finally:
        for original, backup in reversed(hidden):
            if original.exists(): original.replace(original.with_name('prefix.validation-created-' + str(uuid.uuid4())))
            backup.replace(original)

def exercise(args, runtime, manifest):
    environment = {k: v for k, v in os.environ.items() if not k.startswith(('GIT_', 'PERL', 'DYLD_'))}
    environment.update(PATH=str(args.git.resolve().parent) + ':/usr/bin:/bin:/usr/sbin:/sbin', GIT_EXEC_PATH=str(args.git.resolve().parent.parent / 'libexec/git-core'),
        GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_TERMINAL_PROMPT='0')
    import platform
    arch = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
    bucket = runtime / 'libexec/git-svn-runtime' / arch
    dispatcher = runtime / 'libexec/git-core/git-svn'
    def run(executable, *arguments, **options):
        return subprocess.check_output([str(executable), *map(str, arguments)], env=environment, stderr=subprocess.STDOUT, timeout=90, **options)
    version = run(dispatcher, '--version').decode().strip()
    assert ('git-svn version ' + manifest['git']['version']) in version, version
    assert ('svn ' + manifest['pin']['sources']['subversion']['version']) in version, version
    with tempfile.TemporaryDirectory(prefix='TurtleGitSVNRuntime-雪-') as temporary:
        folder = Path(temporary); repository = folder / 'svn-repo'; wc = folder / 'svn-wc'; git_wc = folder / 'git-wc'
        config = folder / 'svn-config'; config.mkdir()
        run(bucket / 'Subversion/bin/svnadmin', 'create', repository)
        def svn(*arguments): return run(bucket / 'Subversion/bin/svn', '--config-dir', config, '--non-interactive', *arguments)
        environment['TURTLEGIT_SVN_CONFIG_DIR'] = str(config)
        def bridge(*arguments, cwd=None): return run(dispatcher, *arguments, cwd=cwd)
        svn('checkout', repository.as_uri(), wc)
        (wc / 'file 雪.txt').write_bytes(b'base\n')
        svn('add', wc / 'file 雪.txt'); svn('propset', 'svn:ignore', 'ignored*', wc)
        svn('commit', '-m', 'base', wc)
        bridge('clone', repository.as_uri(), git_wc)
        assert (git_wc / 'file 雪.txt').read_bytes() == b'base\n'
        assert (git_wc / '.git/svn/.metadata').is_file()
        run(args.git, '-C', git_wc, 'config', 'user.name', 'SVN Runtime QA')
        run(args.git, '-C', git_wc, 'config', 'user.email', 'qa@example.invalid')
        run(args.git, '-C', git_wc, 'config', 'commit.gpgsign', 'false')
        before = run(args.git, '-C', git_wc, 'rev-parse', 'HEAD').strip()
        index = (git_wc / '.git/index').read_bytes()
        (wc / 'file 雪.txt').write_bytes(b'from svn\n'); svn('commit', '-m', 'svn next', wc)
        bridge('fetch', cwd=git_wc)
        after = run(args.git, '-C', git_wc, 'rev-parse', 'refs/remotes/git-svn').strip()
        assert before != after and run(args.git, '-C', git_wc, 'rev-parse', 'HEAD').strip() == before
        assert (git_wc / '.git/index').read_bytes() == index
        run(args.git, '-C', git_wc, 'reset', '--hard', after.decode())
        (git_wc / 'file 雪.txt').write_bytes(b'from git\n'); run(args.git, '-C', git_wc, 'add', '--', 'file 雪.txt')
        run(args.git, '-C', git_wc, 'commit', '-m', 'git change'); bridge('dcommit', '--rmdir', cwd=git_wc)
        svn('update', wc); assert (wc / 'file 雪.txt').read_bytes() == b'from git\n'
        ignores = bridge('show-ignore', cwd=git_wc); assert b'ignored*' in ignores
        bridge('create-ignore', cwd=git_wc); assert b'ignored*' in (git_wc / '.gitignore').read_bytes()
        print('Real private file:// SVN clone/fetch/dcommit/show-ignore/create-ignore passed; no public server or app launched.')

if __name__ == '__main__':
    try: main()
    except subprocess.CalledProcessError as failure:
        if failure.output: print(failure.output.decode('utf-8', errors='replace'), file=sys.stderr)
        raise
