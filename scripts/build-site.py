#!/usr/bin/env python3
"""Build the static GitHub Pages site; repository links survive a later rename."""
import json
import os
import pathlib
import re
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
repository = os.environ.get('GITHUB_REPOSITORY')
if not repository:
    remote = subprocess.check_output(['git', '-C', str(root), 'remote', 'get-url', 'origin'], text=True).strip()
    match = re.fullmatch(r'(?:https://github\.com/|git@github\.com:)([\w.-]+/[\w.-]+?)(?:\.git)?', remote)
    if not match:
        raise SystemExit('Set GITHUB_REPOSITORY to owner/repository for Pages links.')
    repository = match.group(1)
if not re.fullmatch(r'[\w.-]+/[\w.-]+', repository):
    raise SystemExit('Invalid GITHUB_REPOSITORY.')
source = root / 'docs/site'
destination = root / 'build/site'
for screenshot in ['log-messages.png', 'status.png', 'commit.png', 'staging.png', 'partial-staging.png', 'switch-checkout.png', 'create-branch.png', 'create-tag.png', 'push.png', 'fetch.png', 'pull.png', 'rebase.png', 'rebase-dark.png', 'commit-light.png', 'commit-dark.png']:
    path = source / 'assets' / screenshot
    if not path.is_file() or path.read_bytes()[:8] != b'\x89PNG\r\n\x1a\n':
        raise SystemExit(f'Missing native screenshot: {path}')
shutil.copytree(source, destination, dirs_exist_ok=True)
manifest = json.loads((root / 'docs/upstream.json').read_text())
index = (destination / 'index.html').read_text()
for token, value in {'REPOSITORY_URL': 'https://github.com/' + repository,
                     'FILE_COUNT': f"{manifest['tracked_entries']:,}",
                     'DIALOG_COUNT': str(manifest['dialog_resources'])}.items():
    index = index.replace('@@' + token + '@@', value)
if '@@' in index:
    raise SystemExit('Unresolved website token.')
(destination / 'index.html').write_text(index)
(destination / '.nojekyll').touch()
print(destination)
