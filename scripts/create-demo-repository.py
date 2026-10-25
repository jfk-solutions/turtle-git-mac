#!/usr/bin/env python3
"""Create disposable sample data for UI verification and documentation captures."""
import argparse
import pathlib
import datetime
import os
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('destination', type=pathlib.Path)
parser.add_argument('--git', default='/usr/bin/git', help='Git executable used only for the disposable demo')
parser.add_argument('--clean', action='store_true', help='Leave committed history without preview edits')
parser.add_argument('--deterministic', action='store_true', help='Use fixed synthetic author and commit dates')
args = parser.parse_args()
root = args.destination.resolve()
if root.exists():
    raise SystemExit('Destination already exists. Choose a new path; this script never overwrites repositories.')
root.mkdir(parents=True)

environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
environment.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0', LC_ALL='C')
sequence = 0

def git(*arguments):
    global sequence
    current = dict(environment)
    if args.deterministic:
        date = (datetime.datetime(2026, 1, 1, 12, tzinfo=datetime.timezone.utc) + datetime.timedelta(days=sequence)).isoformat()
        current.update(GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
        if arguments[0] in ('commit', 'merge', 'tag'):
            sequence += 1
    subprocess.run([args.git, '-C', str(root), *arguments], check=True, stdout=subprocess.DEVNULL, env=current)

def write(path, text):
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)

template = root.parent / ('.' + root.name + '-empty-template')
if template.exists():
    raise SystemExit('Demo template path already exists; choose another destination.')
template.mkdir()
try:
    git('init', '-b', 'main', '--template=' + str(template))
finally:
    template.rmdir()
git('config', 'user.name', 'TurtleGit Team')
git('config', 'user.email', 'demo@example.invalid')
git('config', 'commit.gpgsign', 'false')
git('config', 'tag.gpgsign', 'false')
write('README.md', '# Harbor\n\nA small macOS project used for the TurtleGit preview.\n')
write('.gitignore', '*.log\n.build/\n')
git('add', '--', 'README.md', '.gitignore')
git('commit', '-m', 'Start the Harbor project')
write('Sources/Repository.swift', 'import Foundation\n\nstruct Repository {\n    let path: URL\n}\n')
git('add', '--', 'Sources/Repository.swift')
git('commit', '-m', 'Add the repository model')
git('switch', '-c', 'feature/status-badges')
write('Sources/BadgeStyle.swift', 'enum BadgeStyle {\n    case green, red, orange\n}\n')
git('add', '--', 'Sources/BadgeStyle.swift')
git('commit', '-m', 'Use familiar colors for repository status')
write('Sources/BadgeStyle.swift', 'enum BadgeStyle {\n    case green, red, orange, gray\n}\n')
git('add', '--', 'Sources/BadgeStyle.swift')
git('commit', '-m', 'Add a badge style for ignored paths')
git('switch', 'main')
write('Tests/RepositoryTests.swift', 'import XCTest\n\nfinal class RepositoryTests: XCTestCase {\n    func testName() { XCTAssertEqual("Harbor", "Harbor") }\n}\n')
git('add', '--', 'Tests/RepositoryTests.swift')
git('commit', '-m', 'Cover the project name')
git('merge', '--no-ff', 'feature/status-badges', '-m', 'Merge status badge styles', '-m', 'Keep familiar repository status colors in native macOS windows.\n\nReviewed with sample repositories and merge history.')
git('tag', '-a', 'v0.1-preview', '-m', 'Documentation sample')

if not args.clean:
    write('README.md', '# Harbor\n\nA small macOS project used for the TurtleGit preview.\n\nOpen a repository, review changes, and commit from native Mac windows.\n')
    write('Sources/Repository.swift', 'import Foundation\n\nstruct Repository {\n    let path: URL\n    var name: String { path.lastPathComponent }\n}\n')
    git('add', '--', 'Sources/Repository.swift')
    write('Sources/StatusBadge.swift', 'enum StatusBadge {\n    case clean, modified, conflicted\n}\n')
    write('preview.log', 'Disposable ignored preview log\n')
print(root)
