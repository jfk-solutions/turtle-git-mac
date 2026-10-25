#!/usr/bin/env python3
"""Build the offline, synthetic App Review attachment; never open a user's repository."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
DEFAULT = ROOT / 'docs/app-store/turtlegit-review-demo-v1.zip'
README = '''TurtleGit for Mac — offline review sample, version 1

All names, email addresses and project contents in this archive are synthetic.
The sample contains no credentials, external server, executable Git hooks,
submodules, alternates, symbolic links or personal repository history.
It is supplied under the accompanying GNU GPL version 2 license.

GET STARTED
1. Extract this archive into a new folder you own. Keep this README, the two
   repositories and History.bundle together. Do not use a personal repository.
2. In TurtleGit choose Open Repository and select Harbor. The normal folder
   chooser grants access. From Finder, Add to TurtleGit registers that selected
   repository for menus/badges without opening a workspace. Enable the extension
   in System Settings if necessary. Registration does not enable refresh after
   Quit automatically.
3. Open Log: inspect main, feature/status-badges, feature/offline-help,
   release/1.0, the merge commits and the annotated preview/release tags. Select
   commits to inspect messages, changed paths, comparisons and Blame.
4. Open Check for modifications or Commit. Sources/Repository.swift has BOTH
   staged and unstaged changes. README.md is modified, Docs/QuickStart.md was
   renamed to Docs/GettingStarted.md, Tests/StatusBadgeTests.swift is added, and
   Notes/review-notes.md is untracked. preview.log is ignored. Row highlighting
   and checked membership are independent. With staging enabled, inspect both
   versions before choosing which changes to commit. No signing key is needed;
   a synthetic author is configured only inside these disposable repositories.
5. Open review.patch as a document to inspect the standalone editable Unified
   Diff viewer. Use Save As to a new destination to preserve the supplied patch.
   The matching commit is already in Harbor, so do not apply the patch there.
6. For offline Clone, paste the full path of History.bundle into Clone's URL /
   source field, and choose a NEW empty destination outside this archive. The
   source Browse chooser selects folders; it does not select bundle files. If
   access is requested, authorize the containing sample folder. The clone has
   clean committed history,
   without Harbor's demonstration edits. Successful Clone should register its
   destination automatically. The bundle is a read-only sample source; do not
   attempt Push or require any online account to review this attachment.
7. Open Harbor Conflict. It intentionally has an unfinished merge, with one
   conflict in Sources/BadgeStyle.swift. Compare/resolve it, choose the desired
   content, save and mark it resolved. Commit to finish the sample merge, or
   choose Abort Merge to return to its main branch. Do not assume the original
   conflict remains after resolving/aborting; extract a fresh copy to repeat.

EXPECTED INITIAL STATE
expected.json records the exact commit IDs, branches, tags and porcelain status
for both repositories, and the patch/bundle checksums. It describes the supplied
initial state, not a state TurtleGit must force after your review mutations.

RESET AND CLEANUP
Extract a new copy to a different folder to start again. The generator never
resets or overwrites an existing checkout. After review, remove only these sample
repositories from TurtleGit's saved access/watched roots and discard the sample
folder or your explicit clone. Restore any background-refresh preference you
changed. Do not clear unrelated histories, grants, Keychain items or Finder
windows. The app and Finder extension need no blanket disk permission.

This is local review data, not evidence of complete upstream parity, network
authentication, Office automation, email delivery or App Store approval.
'''


def sha(data):
    return hashlib.sha256(data).hexdigest()


def build(git, destination):
    environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    environment.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0', GIT_OPTIONAL_LOCKS='0', GIT_AUTHOR_NAME='TurtleGit Team', GIT_AUTHOR_EMAIL='demo@example.invalid', GIT_COMMITTER_NAME='TurtleGit Team', GIT_COMMITTER_EMAIL='demo@example.invalid', LC_ALL='C')
    with tempfile.TemporaryDirectory(prefix='turtlegit-review-authoring-') as temporary:
        parent = Path(temporary) / 'TurtleGit Review Sample'
        parent.mkdir()
        harbor = parent / 'Harbor'
        subprocess.run([sys.executable, str(ROOT / 'scripts/create-demo-repository.py'), str(harbor),
                        '--git', str(git), '--clean', '--deterministic'], check=True, env=environment,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        sequence = 20

        def command(repo, *arguments, data=None, allowed=(0,)):
            nonlocal sequence
            current = dict(environment)
            date = (datetime.datetime(2026, 1, 1, 12, tzinfo=datetime.timezone.utc) +
                    datetime.timedelta(days=sequence)).isoformat()
            current.update(GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
            if arguments[0] in ('commit', 'merge', 'tag'):
                sequence += 1
            result = subprocess.run([str(git), '-C', str(repo), *arguments], input=data,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=current)
            if result.returncode not in allowed:
                raise RuntimeError(result.stderr.decode('utf-8', 'replace'))
            return result.stdout

        def write(repo, name, text):
            target = repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open('w', encoding='utf-8', newline='\n') as stream:
                stream.write(text)

        write(harbor, 'LICENSE', (ROOT / 'LICENSE').read_text())
        write(harbor, 'Docs/QuickStart.md', '# Harbor quick start\n\nOpen a repository, inspect changes and commit.\n')
        command(harbor, 'add', '--', 'LICENSE', 'Docs/QuickStart.md')
        command(harbor, 'commit', '-m', 'Document the offline Harbor sample')
        command(harbor, 'switch', '-c', 'feature/offline-help')
        write(harbor, 'Docs/Help.md', '# Offline help\n\nKeep repository instructions available without a network connection.\n')
        command(harbor, 'add', '--', 'Docs/Help.md')
        command(harbor, 'commit', '-m', 'Add offline repository help', '-m', 'Keep the first-use workflow available without external services.')
        command(harbor, 'switch', 'main')
        write(harbor, 'Sources/StatusSummary.swift', 'struct StatusSummary {\n    var modified = 0\n    var staged = 0\n    var untracked = 0\n}\n')
        command(harbor, 'add', '--', 'Sources/StatusSummary.swift')
        command(harbor, 'commit', '-m', 'Separate staged, modified and untracked counts')
        command(harbor, 'merge', '--no-ff', 'feature/offline-help', '-m', 'Merge offline help', '-m', 'Preserve a visible branch and merge in the history graph.')
        command(harbor, 'branch', 'release/1.0')
        command(harbor, 'tag', '-a', 'v1.0-demo', '-m', 'Offline review sample release')
        write(harbor, 'Docs/Review.md', '# Review changes\n\nCompare the staged and working versions before committing.\n')
        command(harbor, 'add', '--', 'Docs/Review.md')
        command(harbor, 'commit', '-m', 'Explain staged and working-tree review')
        patch = command(harbor, 'format-patch', '-1', '--stdout', '--no-signature', 'HEAD')
        (parent / 'review.patch').write_bytes(patch)
        command(harbor, 'bundle', 'create', str(parent / 'History.bundle'), '--branches', '--tags', 'HEAD')

        conflict = parent / 'Harbor Conflict'
        command(parent, 'clone', '-b', 'main', '--no-local', 'History.bundle', str(conflict))
        command(conflict, 'reflog', 'expire', '--expire=all', '--all')
        command(conflict, 'remote', 'remove', 'origin')
        for key, value in [('user.name', 'TurtleGit Team'), ('user.email', 'demo@example.invalid'),
                           ('commit.gpgsign', 'false'), ('tag.gpgsign', 'false'),
                           ('turtlegit.reviewDemo', 'true')]:
            command(conflict, 'config', key, value)
        command(conflict, 'switch', '-c', 'feature/review-colors')
        write(conflict, 'Sources/BadgeStyle.swift', 'enum BadgeStyle {\n    case cleanGreen, changedAmber, conflictRed, ignoredGray\n}\n')
        command(conflict, 'add', '--', 'Sources/BadgeStyle.swift')
        command(conflict, 'commit', '-m', 'Name badge colors by repository state')
        command(conflict, 'switch', 'main')
        write(conflict, 'Sources/BadgeStyle.swift', 'enum BadgeStyle {\n    case green, red, orange, gray, blue\n}\n')
        command(conflict, 'add', '--', 'Sources/BadgeStyle.swift')
        command(conflict, 'commit', '-m', 'Add a badge color for incoming changes')
        command(conflict, 'merge', '--no-ff', 'feature/review-colors', '-m', 'Merge the review badge colors', allowed=(1,))

        command(harbor, 'config', 'turtlegit.reviewDemo', 'true')
        command(harbor, 'remote', 'add', 'origin', '../History.bundle')
        command(harbor, 'update-ref', 'refs/remotes/origin/main', command(harbor, 'rev-parse', 'HEAD').decode().strip())
        command(harbor, 'config', 'branch.main.remote', 'origin')
        command(harbor, 'config', 'branch.main.merge', 'refs/heads/main')
        write(harbor, 'Sources/Repository.swift', 'import Foundation\n\nstruct Repository {\n    let path: URL\n    var name: String { path.lastPathComponent }\n}\n')
        command(harbor, 'add', '--', 'Sources/Repository.swift')
        with (harbor / 'Sources/Repository.swift').open('a') as stream:
            stream.write('\n// Working-tree draft: keep the staged change separate.\n')
        with (harbor / 'README.md').open('a') as stream:
            stream.write('\nReview changes in native Mac windows before committing.\n')
        command(harbor, 'mv', 'Docs/QuickStart.md', 'Docs/GettingStarted.md')
        write(harbor, 'Tests/StatusBadgeTests.swift', 'import XCTest\n\nfinal class StatusBadgeTests: XCTestCase {\n    func testStatusName() { XCTAssertEqual("clean", "clean") }\n}\n')
        command(harbor, 'add', '--', 'Tests/StatusBadgeTests.swift')
        write(harbor, 'Notes/review-notes.md', '# Review notes\n\nThis file is intentionally untracked.\n')
        write(harbor, 'preview.log', 'Intentionally ignored review log\n')

        # Rebuild the index from its exact stage entries to remove machine-local
        # inode/stat cache data while keeping the prepared staged/conflict bytes.
        for repo in (harbor, conflict):
            entries = command(repo, 'ls-files', '--stage', '-z')
            command(repo, 'read-tree', '--empty')
            command(repo, 'update-index', '-z', '--index-info', data=entries)
            (repo / '.git/description').write_text('Synthetic offline TurtleGit review repository\n')
            hooks = repo / '.git/hooks'
            if hooks.is_dir():
                for hook in hooks.iterdir():
                    if not hook.name.endswith('.sample'):
                        raise RuntimeError('Unexpected executable Git hook in generated sample')
                    hook.unlink()
                hooks.rmdir()

        expected = {'schema': 'TurtleGitOfflineReviewSampleV1', 'git_version': command(harbor, '--version').decode().strip(),
                    'repositories': {}, 'review_patch_sha256': sha(patch),
                    'history_bundle_sha256': sha((parent / 'History.bundle').read_bytes()),
                    'privacy': 'Synthetic local data only; no credentials, personal history or network remotes.'}
        for repo in (harbor, conflict):
            expected['repositories'][repo.name] = {
                'head': command(repo, 'rev-parse', 'HEAD').decode().strip(),
                'branches': command(repo, 'for-each-ref', '--format=%(refname:short)', 'refs/heads').decode().splitlines(),
                'tags': command(repo, 'tag', '--list').decode().splitlines(),
                'status_porcelain': command(repo, 'status', '--porcelain=v1', '--untracked-files=all').decode().splitlines(),
                'commit_count': int(command(repo, 'rev-list', '--all', '--count'))}
        (parent / 'expected.json').write_text(json.dumps(expected, indent=2) + '\n')
        (parent / 'README.txt').write_text(README)
        (parent / 'LICENSE').write_bytes((ROOT / 'LICENSE').read_bytes())
        destination.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for path in sorted(parent.rglob('*')):
                if path.is_symlink():
                    raise RuntimeError('Sample contains a symbolic link')
                if path.is_file():
                    entry = zipfile.ZipInfo(str(path.relative_to(parent.parent)), (2026, 1, 1, 12, 0, 0))
                    entry.external_attr = 0o100644 << 16
                    entry.compress_type = zipfile.ZIP_DEFLATED
                    archive.writestr(entry, path.read_bytes())
        manifest = {'schema': 'TurtleGitReviewAttachmentV1', 'archive': destination.name,
                    'sha256': sha(destination.read_bytes()), 'bytes': destination.stat().st_size,
                    'expected': expected, 'files': {info.filename: sha(archive_bytes)
                    for info, archive_bytes in archive_contents(destination)}}
        destination.with_suffix('.manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        print(json.dumps({key: manifest[key] for key in ('archive', 'sha256', 'bytes')}))


def archive_contents(path):
    with zipfile.ZipFile(path) as archive:
        return [(entry, archive.read(entry)) for entry in archive.infolist()]


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--git', type=Path, default=ROOT / 'build/git-runtime/Git/bin/git')
    parser.add_argument('--output', type=Path, default=DEFAULT)
    args = parser.parse_args()
    build(args.git.resolve(strict=True), args.output.resolve())
