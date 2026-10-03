#!/usr/bin/env python3
"""Make an independent unsigned Debug app for documentation; never replace the user's running app."""
import argparse
import pathlib
import plistlib
import shutil

parser = argparse.ArgumentParser()
parser.add_argument('source', type=pathlib.Path)
parser.add_argument('destination', type=pathlib.Path)
parser.add_argument('--repository', required=True, type=pathlib.Path)
parser.add_argument('--swift-executable', type=pathlib.Path, help='Use a Swift Package Debug executable when Xcode is unavailable.')
args = parser.parse_args()
if args.destination.exists():
    raise SystemExit('Preview destination already exists. Choose another path.')
if not (args.repository / '.git').exists():
    raise SystemExit('Use a disposable demo repository created with create-demo-repository.py.')
shutil.copytree(args.source, args.destination, symlinks=True)
info = args.destination / 'Contents/Info.plist'
with info.open('rb') as stream:
    data = plistlib.load(stream)
data['CFBundleIdentifier'] = 'org.turtlegit.macos.documentation-preview'
data['CFBundleName'] = 'TurtleGit Documentation Preview'
data['CFBundleDisplayName'] = 'TurtleGit Documentation Preview'
data['TurtleGitDocumentationRepository'] = str(args.repository.resolve())
data.pop('CFBundleURLTypes', None)
with info.open('wb') as stream:
    plistlib.dump(data, stream)
if args.swift_executable:
    executable = args.swift_executable.resolve()
    shutil.copy2(executable, args.destination / 'Contents/MacOS' / data['CFBundleExecutable'])
    resources = executable.parent / 'TurtleGitMac_TurtleGitCore.bundle'
    if not resources.is_dir():
        raise SystemExit('Swift Package icon resource bundle is missing. Run swift build first.')
    shutil.copytree(resources, args.destination / resources.name, symlinks=True)
print(args.destination.resolve())
