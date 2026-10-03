#!/usr/bin/env python3
"""Create disposable sample data for UI verification and documentation captures."""
import argparse
import pathlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('destination', type=pathlib.Path)
args = parser.parse_args()
root = args.destination.resolve()
if root.exists():
    raise SystemExit('Destination already exists. Choose a new path; this script never overwrites repositories.')
root.mkdir(parents=True)

def git(*arguments):
    subprocess.run(['git', '-C', str(root), *arguments], check=True, stdout=subprocess.DEVNULL)

def write(path, text):
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)

git('init', '-b', 'main')
git('config', 'user.name', 'TurtleGit Team')
git('config', 'user.email', 'demo@example.invalid')
git('config', 'commit.gpgsign', 'false')
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

write('README.md', '# Harbor\n\nA small macOS project used for the TurtleGit preview.\n\nOpen a repository, review changes, and commit from native Mac windows.\n')
write('Sources/Repository.swift', 'import Foundation\n\nstruct Repository {\n    let path: URL\n    var name: String { path.lastPathComponent }\n}\n')
git('add', '--', 'Sources/Repository.swift')
write('Sources/StatusBadge.swift', 'enum StatusBadge {\n    case clean, modified, conflicted\n}\n')
write('preview.log', 'Disposable ignored preview log\n')
print(root)
