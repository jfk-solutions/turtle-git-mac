#!/usr/bin/env python3
"""Install a verified SVN component into the prepared pinned Git runtime."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('component', type=Path)
    parser.add_argument('git', type=Path)
    args = parser.parse_args(); component = args.component.resolve(); git = args.git.resolve()
    source = json.loads((component / 'runtime-manifest.json').read_text())
    manifest_file = git / 'runtime-manifest.json'; manifest = json.loads(manifest_file.read_text())
    pin = json.loads((ROOT / 'Configuration/GitRuntime.json').read_text())
    assert source['git'] == pin and manifest['version'] == pin['version'] and manifest['source_sha256'] == pin['source_sha256']
    assert set(source['architectures']) == set(manifest['architectures']), 'Git and SVN component architectures must match.'
    payload = git / 'libexec/git-svn-runtime'
    if payload.exists() and 'svn_component' not in manifest: raise RuntimeError('Refusing to replace an unrecognized SVN payload')
    subprocess.run(['/usr/bin/python3', ROOT / 'scripts/validate-git-svn-runtime.py', component, '--audit-only'], check=True)
    with tempfile.TemporaryDirectory(prefix='.git-svn-install-', dir=git) as temporary:
        staging = Path(temporary)
        shutil.copytree(component / 'libexec/git-svn-runtime', staging / 'payload', symlinks=True)
        shutil.copytree(component / 'share/licenses/git-svn', staging / 'licenses', symlinks=True)
        shutil.copy2(component / 'libexec/git-core/git-svn', staging / 'git-svn')
        shutil.copy2(component / 'runtime-manifest.json', staging / 'licenses/runtime-manifest.json')
        replacements = [(staging / 'payload', payload), (staging / 'licenses', git / 'share/licenses/git-svn'),
            (staging / 'git-svn', git / 'libexec/git-core/git-svn')]
        moved = []
        try:
            for index, (prepared, target) in enumerate(replacements):
                target.parent.mkdir(parents=True, exist_ok=True)
                backup = staging / ('previous-' + str(index))
                if target.exists(): target.replace(backup)
                moved.append((target, backup)); prepared.replace(target)
            manifest['svn_component'] = {'version': source['pin']['sources']['subversion']['version'],
                'perl': source['pin']['sources']['perl']['version'], 'manifest': 'share/licenses/git-svn/runtime-manifest.json',
                'acceptance': 'private local integration and signed distribution have separate validation gates'}
            feature = 'git-svn-private-perl-subversion'
            if feature not in manifest['features']: manifest['features'].append(feature)
            manifest['excluded'] = ['other-perl-tools' if x == 'perl-tools' else x for x in manifest.get('excluded', [])]
            next_manifest = staging / 'runtime-manifest.json'; next_manifest.write_text(json.dumps(manifest, indent=2) + '\n'); next_manifest.replace(manifest_file)
        except Exception:
            for target, backup in reversed(moved):
                if target.is_dir(): shutil.rmtree(target)
                else: target.unlink(missing_ok=True)
                if backup.exists(): backup.replace(target)
            raise
    print('Installed private Git SVN component:', git)

if __name__ == '__main__': main()
