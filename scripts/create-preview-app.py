#!/usr/bin/env python3
"""Make an independent ad-hoc-signed Debug app for documentation; never replace the user's running app."""
import argparse
import pathlib
import plistlib
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('source', type=pathlib.Path)
parser.add_argument('destination', type=pathlib.Path)
parser.add_argument('--repository', required=True, type=pathlib.Path)
parser.add_argument('--swift-executable', type=pathlib.Path, help='Use a Swift Package Debug executable when Xcode is unavailable.')
parser.add_argument('--bundle-identifier', default='org.turtlegit.macos.documentation-preview')
parser.add_argument('--name', default='TurtleGit Documentation Preview')
parser.add_argument('--screenshot', type=pathlib.Path, help='Debug-only destination for the Save Window Screenshot command.')
parser.add_argument('--appearance', choices=['system', 'light', 'dark'], help='Debug-only initial appearance.')
args = parser.parse_args()
if args.destination.exists():
    raise SystemExit('Preview destination already exists. Choose another path.')
if not (args.repository / '.git').exists():
    raise SystemExit('Use a disposable demo repository created with create-demo-repository.py.')
if args.screenshot and args.screenshot.exists():
    raise SystemExit('Screenshot destination already exists. Choose another path.')
shutil.copytree(args.source, args.destination, symlinks=True)
info = args.destination / 'Contents/Info.plist'
with info.open('rb') as stream:
    data = plistlib.load(stream)
data['CFBundleIdentifier'] = args.bundle_identifier
data['CFBundleName'] = args.name
data['CFBundleDisplayName'] = args.name
data['TurtleGitDocumentationRepository'] = str(args.repository.resolve())
data.pop('CFBundleURLTypes', None)
if args.appearance:
    data['TurtleGitDocumentationAppearance'] = args.appearance
else:
    data.pop('TurtleGitDocumentationAppearance', None)
if args.screenshot:
    data['TurtleGitDocumentationCapturePath'] = str(args.screenshot.resolve())
else:
    data.pop('TurtleGitDocumentationCapturePath', None)
with info.open('wb') as stream:
    plistlib.dump(data, stream)
if args.swift_executable:
    executable = args.swift_executable.resolve()
    shutil.copy2(executable, args.destination / 'Contents/MacOS' / data['CFBundleExecutable'])
    resources = executable.parent / 'TurtleGitMac_TurtleGitCore.bundle'
    if not resources.is_dir():
        raise SystemExit('Swift Package icon resource bundle is missing. Run swift build first.')
    shutil.copytree(resources, args.destination / 'Contents/Resources' / resources.name, symlinks=True, dirs_exist_ok=True)

# A replaced executable invalidates the copied bundle signature. Keep Swift resources
# inside Contents/Resources so the preview passes bundle signature validation.
legacy_resources = args.destination / 'TurtleGitMac_TurtleGitCore.bundle'
if legacy_resources.exists():
    shutil.rmtree(legacy_resources)
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(args.destination)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.destination)], check=True)

print(args.destination.resolve())
