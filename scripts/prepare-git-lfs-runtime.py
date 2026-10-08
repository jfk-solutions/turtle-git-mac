#!/usr/bin/env python3
"""Add publisher-pinned universal Git LFS and complete notices to a prepared Git runtime."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
from git_lfs_runtime import ROOT, archive_names, cached, digest, module_hash, pin

def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('runtime', type=Path); args = parser.parse_args()
    runtime = args.runtime.resolve(); manifest = json.loads((runtime / 'runtime-manifest.json').read_text()); config = pin()
    (ROOT / 'build/git-lfs-source').mkdir(parents=True, exist_ok=True)
    if (runtime / 'git-lfs-manifest.json').exists():
        subprocess.run(['/usr/bin/python3', ROOT / 'scripts/validate-git-lfs-runtime.py', runtime], check=True); return
    if (runtime / 'bin/git-lfs').exists(): raise ValueError('Unmanaged Git LFS executable already exists')
    with tempfile.TemporaryDirectory(prefix='turtlegit-lfs-prepare-', dir=ROOT / 'build/git-lfs-source') as temporary:
        stage = Path(temporary); licenses = stage / 'licenses'; licenses.mkdir(); binaries = []
        source = cached(config['source']); shutil.copy2(source, licenses / source.name)
        with tarfile.open(source) as archive:
            (licenses / 'LICENSE.md').write_bytes(archive.extractfile(config['source']['prefix'] + '/LICENSE.md').read())
        for arch in manifest['architectures']:
            record = config['artifacts'][arch]; archive_path = cached(record); shutil.copy2(archive_path, licenses / archive_path.name)
            with zipfile.ZipFile(archive_path) as archive:
                archive_names(archive); data = archive.read(record['binary_member']); assert digest(data) == record['binary_sha256']
            binary = stage / ('git-lfs-' + arch); binary.write_bytes(data); binary.chmod(0o755); binaries.append(binary)
        for name, record in config['go_notices'].items():
            target = licenses / 'go' / name; target.parent.mkdir(exist_ok=True); shutil.copy2(cached(record), target)
        for module, record in config['modules'].items():
            with zipfile.ZipFile(cached(record)) as archive:
                assert module_hash(archive) == record['h1'], module
                for name, checksum in record['license_files_sha256'].items():
                    data = archive.read(name); assert digest(data) == checksum
                    target = licenses / 'modules' / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
        kit = licenses / 'repackage'; (kit / 'scripts').mkdir(parents=True); (kit / 'Configuration').mkdir()
        for name in ['git_lfs_runtime.py', 'prepare-git-lfs-runtime.py', 'validate-git-lfs-runtime.py']:
            shutil.copy2(ROOT / 'scripts' / name, kit / 'scripts' / name)
        shutil.copy2(ROOT / 'Configuration/GitLFSRuntime.json', kit / 'Configuration/GitLFSRuntime.json')
        merged = stage / 'git-lfs'
        subprocess.run(['/usr/bin/lipo', '-create', *binaries, '-output', merged], check=True); merged.chmod(0o755)
        component = {**config, 'architectures': manifest['architectures'], 'packaging': 'Official publisher binaries combined with lipo; replacement signatures permitted, code/data and loader provenance audited.'}
        # Publish only after every archive, module sum and notice was verified.
        destination = runtime / 'share/licenses/git-lfs'; destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists(): raise ValueError('Unmanaged Git LFS notices already exist')
        shutil.copytree(licenses, destination); shutil.copy2(merged, runtime / 'bin/git-lfs')
        (runtime / 'git-lfs-manifest.json').write_text(json.dumps(component, indent=2, sort_keys=True) + '\n')
        manifest['features'] = list(dict.fromkeys(manifest['features'] + ['git-lfs']))
        manifest['excluded'] = [value for value in manifest['excluded'] if value != 'git-lfs']
        (runtime / 'runtime-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    subprocess.run(['/usr/bin/python3', ROOT / 'scripts/validate-git-lfs-runtime.py', runtime], check=True)
    print('Prepared pinned Git LFS in ' + str(runtime))

if __name__ == '__main__': main()
