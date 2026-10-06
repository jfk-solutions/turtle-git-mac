#!/usr/bin/env python3
"""Build isolated older Git binaries for local replay tests; does not change shipped Git."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import posixpath
import subprocess
import tarfile
import tempfile
import urllib.request

root = Path(__file__).resolve().parent.parent
configuration = json.loads((root / 'Configuration/GitReplayTestRuntimes.json').read_text())
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--version', required=True, choices=configuration['versions'])
parser.add_argument('--output', type=Path)
args = parser.parse_args()
if platform.system() != 'Darwin' or platform.machine() not in ('arm64', 'x86_64'):
    parser.error('Use a macOS arm64 or x86_64 host with Xcode command-line tools.')
output = (args.output or root / 'build/replay-test-git' / args.version).resolve()
if output.exists():
    parser.error('Output exists; choose a fresh directory.')
pin = configuration['versions'][args.version]
with urllib.request.urlopen(pin['source_url'], timeout=60) as response:
    data = response.read()
if hashlib.sha256(data).hexdigest() != pin['source_sha256']:
    raise RuntimeError('Source archive SHA-256 mismatch')
sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
clang = subprocess.check_output(['xcrun', '--find', 'clang'], text=True).strip()
architecture = platform.machine()
flags = '-arch ' + architecture + ' -isysroot ' + sdk + ' -mmacosx-version-min=' + configuration['minimum_macos']
options = ['prefix=' + str(output), 'NO_GETTEXT=YesPlease', 'NO_TCLTK=YesPlease',
           'NO_PERL=YesPlease', 'NO_PYTHON=YesPlease', 'NO_CURL=YesPlease',
           'NO_FINK=YesPlease', 'NO_DARWIN_PORTS=YesPlease', 'NO_HOMEBREW=YesPlease',
           'CC=' + clang, 'CFLAGS=-O2 ' + flags, 'LDFLAGS=' + flags]
environment = dict(os.environ, PATH='/usr/bin:/bin:/usr/sbin:/sbin', MACOSX_DEPLOYMENT_TARGET=configuration['minimum_macos'])
with tempfile.TemporaryDirectory(prefix='turtlegit-replay-test-git-') as temporary:
    directory = Path(temporary)
    archive = directory / ('git-' + args.version + '.tar.xz')
    archive.write_bytes(data)
    with tarfile.open(archive) as source:
        for item in source.getmembers():
            path = PurePosixPath(item.name)
            if path.is_absolute() or '..' in path.parts or path.parts[0] != 'git-' + args.version or not (item.isfile() or item.isdir() or item.issym() or item.islnk()):
                raise RuntimeError('Unexpected source archive member: ' + item.name)
            if item.issym() or item.islnk():
                target = PurePosixPath(item.linkname)
                normalized = PurePosixPath(posixpath.normpath(str(path.parent / target) if item.issym() else str(target)))
                if target.is_absolute() or normalized.parts[0] != 'git-' + args.version:
                    raise RuntimeError('Source archive link escapes tree: ' + item.name)
        source.extractall(directory)
    tree = directory / ('git-' + args.version)
    subprocess.run(['/usr/bin/make', '-j8', *options, 'all'], cwd=tree, env=environment, check=True)
    subprocess.run(['/usr/bin/make', *options, 'install'], cwd=tree, env=environment, check=True)
    (output / archive.name).write_bytes(data)
    (output / 'COPYING').write_bytes((tree / 'COPYING').read_bytes())
    manifest = {**pin, 'version': args.version, 'architecture': architecture,
                'minimum_macos': configuration['minimum_macos'], 'test_only': True,
                'features': ['local replay tests'], 'excluded': ['HTTP/HTTPS transport', 'GUI', 'Perl', 'Python'],
                'build_options': options}
    (output / 'replay-test-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
subprocess.run([str(output / 'bin/git'), '--version'], check=True)
print('Built test-only Git: ' + str(output))
