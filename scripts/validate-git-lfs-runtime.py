#!/usr/bin/env python3
"""Audit Git LFS payload against publisher artifacts and bundled notices, including after signing."""
import argparse
import json
from pathlib import Path
import os
import subprocess
import tarfile
import tempfile
import zipfile
from git_lfs_runtime import build_info, digest, fingerprint, pin, slices

def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('runtime', type=Path); args = parser.parse_args()
    runtime = args.runtime.resolve(); config = pin(); component = json.loads((runtime / 'git-lfs-manifest.json').read_text())
    for key, value in config.items(): assert component[key] == value, key
    manifest = json.loads((runtime / 'runtime-manifest.json').read_text()); assert component['architectures'] == manifest['architectures']
    binary = runtime / 'bin/git-lfs'; actual = slices(binary.read_bytes()); assert set(actual) == set(component['architectures'])
    licenses = runtime / 'share/licenses/git-lfs'; source = licenses / config['source']['filename']
    assert digest(source.read_bytes()) == config['source']['sha256']
    with tarfile.open(source) as archive: assert (licenses / 'LICENSE.md').read_bytes() == archive.extractfile(config['source']['prefix'] + '/LICENSE.md').read()
    for arch, data in actual.items():
        record = config['artifacts'][arch]; package = licenses / record['filename']; assert digest(package.read_bytes()) == record['sha256']
        with zipfile.ZipFile(package) as archive: original = archive.read(record['binary_member'])
        assert digest(original) == record['binary_sha256']; assert fingerprint(data) == fingerprint(original), 'Changed Git LFS code/data or loader: ' + arch
        version, modules = build_info(data); assert version == config['go_version']
        assert modules == {name: record['version'] for name, record in config['modules'].items()}
    for name, record in config['go_notices'].items(): assert digest((licenses / 'go' / name).read_bytes()) == record['sha256']
    for module, record in config['modules'].items():
        for name, checksum in record['license_files_sha256'].items(): assert digest((licenses / 'modules' / name).read_bytes()) == checksum, name
    with tempfile.TemporaryDirectory(prefix='turtlegit-lfs-version-') as temporary:
        environment = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        environment.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_EXEC_PATH=str(runtime / 'libexec/git-core'), PATH=str(runtime / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin')
        version = subprocess.check_output([runtime / 'bin/git', 'lfs', 'version'], cwd=temporary, env=environment, text=True).strip()
        assert version.startswith('git-lfs/' + config['version'] + ' ') and 'git ' + config['upstream_commit'][:8] in version
    print('Git LFS ' + config['version'] + ': publisher code/data+loader provenance, Go/module versions, ' + str(len(config['modules'])) + ' dependency notice sets and bundled Git helper lookup verified for ' + ', '.join(actual) + '.')

if __name__ == '__main__': main()
