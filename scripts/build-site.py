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
for screenshot in ['image-open-light.png', 'image-open-dark.png', 'image-colors-light.png', 'image-colors-dark.png', 'image-frames-light.png', 'image-frames-dark.png', 'image-conflict-light.png', 'image-conflict-dark.png', 'unified-diff-viewer-light.png', 'repository-browser.png', 'text-merge.png', 'text-merge-dark.png', 'log-messages.png', 'status.png', 'commit.png', 'commit-merge.png', 'commit-issue.png', 'commit-issue-dark.png', 'commit-issue-links.png', 'commit-issue-links-dark.png', 'commit-message-urls.png', 'commit-message-format.png', 'commit-message-format-dark.png', 'commit-completion.png', 'commit-completion-dark.png', 'commit-snippets.png', 'commit-snippets-popup.png', 'commit-snippets-dark.png', 'staging.png', 'partial-staging.png', 'switch-checkout.png', 'create-branch.png', 'create-tag.png', 'push.png', 'fetch.png', 'pull.png', 'rebase.png', 'rebase-dark.png', 'commit-light.png', 'commit-dark.png', 'commit-controls.png', 'commit-amend.png', 'commit-view-patch.png', 'commit-author-date.png', 'commit-resize.png', 'commit-history.png', 'commit-file-selection.png', 'commit-restore.png', 'revert.png', 'revert-dark.png', 'revert-progress.png', 'submodule-update.png', 'submodule-update-result.png', 'submodule-update-dark.png', 'submodule-diff.png', 'changed-files.png', 'submodule-diff-dark.png', 'changed-files-dark.png', 'two-file-diff-dark.png', 'two-file-edit-dark.png', 'two-file-marked-dark.png', 'two-file-inline-dark.png', 'two-file-inline-light.png', 'blame-dark.png', 'blame-light.png', 'blame-highlight-light.png', 'blame-modes-light.png', 'blame-settings.png', 'blame-presentation-settings.png', 'blame-font-tabs-light.png', 'blame-log-settings.png', 'blame-locator-light.png', 'blame-locator-dark.png', 'blame-navigation-light.png', 'blame-graph-focus-light.png', 'blame-multiple-selection-light.png', 'blame-go-to-line.png', 'blame-find-light.png', 'alternative-editor.png', 'commit-add.png', 'commit-clipboard.png', 'commit-changelist.png', 'commit-groups-light.png', 'commit-groups-dark.png', 'commit-unversioned-preview.png', 'commit-file-pair.png', 'commit-checkbox-selection.png', 'commit-index-flags.png', 'merge.png', 'stash-save.png', 'stash-pop.png', 'reflog.png', 'clone.png', 'create-repository.png', 'rename.png', 'ignore.png']:
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
