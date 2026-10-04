#!/usr/bin/env python3
"""Build a pinned, relocatable Git with Apple's SDK libraries; no installed Git required."""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import posixpath
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
MACH = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
def macho(path):
    return path.is_file() and not path.is_symlink() and path.open('rb').read(4) in MACH

def run(args, **kwargs):
    subprocess.run([str(value) for value in args], check=True, **kwargs)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / 'build/git-runtime/Git')
    parser.add_argument('--architectures', nargs='+', choices=['arm64', 'x86_64'], default=['arm64', 'x86_64'])
    parser.add_argument('--jobs', type=int, default=min(os.cpu_count() or 2, 8))
    args = parser.parse_args()
    if platform.system() != 'Darwin': parser.error('Build on macOS with Xcode or Command Line Tools.')
    if args.jobs < 1 or args.jobs > 64: parser.error('Use 1 through 64 build jobs.')
    if args.output.exists(): parser.error('Output already exists; select a new output directory.')
    pin = json.loads((ROOT / 'Configuration/GitRuntime.json').read_text())
    cache = ROOT / 'build/git-source'; cache.mkdir(parents=True, exist_ok=True)
    archive = cache / ('git-' + pin['version'] + '.tar.xz')
    if not archive.exists():
        with urllib.request.urlopen(pin['source_url'], timeout=90) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != pin['source_sha256']: raise RuntimeError('Source checksum mismatch')
        archive.write_bytes(data)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != pin['source_sha256']: raise RuntimeError('Cached source checksum mismatch')
    clang = subprocess.check_output(['/usr/bin/xcrun', '--find', 'clang'], text=True).strip()
    sdk = subprocess.check_output(['/usr/bin/xcrun', '--show-sdk-path'], text=True).strip()
    environment = dict(os.environ, PATH='/usr/bin:/bin:/usr/sbin:/sbin', MACOSX_DEPLOYMENT_TARGET=pin['minimum_macos'])
    # Reject traversal and links escaping the source tree before extraction.
    # This also works with the macOS Python 3.9 tarfile implementation.
    with tempfile.TemporaryDirectory(prefix='turtlegit-git-build-', dir=cache) as temporary:
        work = pathlib.Path(temporary); installations = []
        for arch in dict.fromkeys(args.architectures):
            directory = work / arch; directory.mkdir()
            with tarfile.open(archive) as source:
                for item in source.getmembers():
                    path = pathlib.PurePosixPath(item.name)
                    if path.is_absolute() or '..' in path.parts or path.parts[0] != 'git-' + pin['version'] or not (item.isfile() or item.isdir() or item.issym() or item.islnk()):
                        raise RuntimeError('Unexpected source archive member: ' + item.name)
                    if item.issym() or item.islnk():
                        target = pathlib.PurePosixPath(item.linkname)
                        normalized = pathlib.PurePosixPath(posixpath.normpath(str(path.parent / target) if item.issym() else str(target)))
                        if target.is_absolute() or normalized.parts[0] != 'git-' + pin['version']:
                            raise RuntimeError('Source archive link escapes tree: ' + item.name)
                source.extractall(directory)
            tree = directory / ('git-' + pin['version']); stage = directory / 'stage'
            flags = '-O2 -arch ' + arch + ' -isysroot ' + sdk + ' -mmacosx-version-min=' + pin['minimum_macos']
            options = ['prefix=/TurtleGit/Git', 'RUNTIME_PREFIX=YesPlease', 'INSTALL_SYMLINKS=YesPlease',
                       'NO_RUST=YesPlease', 'NO_GETTEXT=YesPlease', 'NO_TCLTK=YesPlease', 'NO_PERL=YesPlease', 'NO_PYTHON=YesPlease',
                       'NO_FINK=YesPlease', 'NO_DARWIN_PORTS=YesPlease', 'NO_HOMEBREW=YesPlease',
                       'CC=' + clang, 'CFLAGS=' + flags, 'LDFLAGS=-arch ' + arch + ' -isysroot ' + sdk + ' -mmacosx-version-min=' + pin['minimum_macos']]
            run(['/usr/bin/make', '-j' + str(args.jobs), *options, 'all', 'contrib/credential/osxkeychain/git-credential-osxkeychain'], cwd=tree, env=environment)
            run(['/usr/bin/make', *options, 'DESTDIR=' + str(stage), 'install', 'install-git-credential-osxkeychain'], cwd=tree, env=environment)
            installations.append(stage / 'TurtleGit/Git')
        prepared = work / 'Git'; shutil.copytree(installations[0], prepared, symlinks=True)
        for path in sorted(prepared.rglob('*')):
            if path.is_dir() or path.is_symlink(): continue
            relative = path.relative_to(prepared)
            siblings = [install / relative for install in installations]
            if macho(path) and len(siblings) > 1:
                merged = path.with_name(path.name + '.universal')
                run(['/usr/bin/lipo', '-create', *siblings, '-output', merged])
                merged.chmod(path.stat().st_mode); merged.replace(path)
            elif any(other.read_bytes() != path.read_bytes() for other in siblings[1:]):
                raise RuntimeError('Architecture-dependent non-binary resource: ' + str(relative))
        licenses = prepared / 'share/licenses/git'; licenses.mkdir(parents=True)
        shutil.copy2(archive, licenses / archive.name)
        shutil.copy2(tree / 'COPYING', licenses / 'COPYING')
        reconstruction = licenses / 'build'
        (reconstruction / 'scripts').mkdir(parents=True)
        (reconstruction / 'Configuration').mkdir()
        for script in ['build-git-runtime.py', 'validate-git-runtime.py']:
            shutil.copy2(ROOT / 'scripts' / script, reconstruction / 'scripts' / script)
        shutil.copy2(ROOT / 'Configuration/GitRuntime.json', reconstruction / 'Configuration/GitRuntime.json')
        shutil.copy2(tree / 'reftable/LICENSE', licenses / 'REFTable-LICENSE')
        shutil.copy2(tree / 'sha1dc/LICENSE.txt', licenses / 'SHA1DC-LICENSE.txt')
        (licenses / 'README.txt').write_text('The complete unmodified Git source archive and build scripts are included.\nTo rebuild, run: python3 build/scripts/build-git-runtime.py\nThe script verifies the pinned archive checksum and uses the macOS SDK.\nGit is GPL v2; retained third-party notices are also present in the source archive.\n')
        (prepared / 'runtime-manifest.json').write_text(json.dumps({**pin, 'architectures': list(dict.fromkeys(args.architectures)),
             'compiler': subprocess.check_output([clang, '--version'], text=True).splitlines()[0],
             'features': ['local-git', 'https-system-libcurl', 'credential-osxkeychain'],
             'excluded': ['git-gui', 'gitk', 'perl-tools', 'python-tools', 'git-lfs']}, indent=2) + '\n')
        run(['/usr/bin/python3', ROOT / 'scripts/validate-git-runtime.py', prepared])
        args.output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(prepared, args.output, symlinks=True)
    print('Built pinned Git runtime: ' + str(args.output.resolve()))

if __name__ == '__main__': main()
