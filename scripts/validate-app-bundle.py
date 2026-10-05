#!/usr/bin/env python3
"""Check unsigned build packaging; does not assert signing or sandbox activation."""
import argparse
import hashlib
import json
import pathlib
import plistlib

parser = argparse.ArgumentParser()
parser.add_argument('app', type=pathlib.Path)
parser.add_argument('--require-git', action='store_true', help='Require and audit a packaged App Store Git runtime.')
args = parser.parse_args()
app = args.app
root = pathlib.Path(__file__).resolve().parent.parent
with (app / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleIdentifier'] == 'org.turtlegit.macos'
assert (app / 'Contents/MacOS' / info['CFBundleExecutable']).is_file()
resources = app / 'Contents/Resources'
assert (resources / 'LICENSE').is_file() and (resources / 'NOTICE').is_file()
framework = app / 'Contents/Frameworks/TurtleGitCore.framework'
icons = framework / 'Resources/Icons'
manifest = json.loads((root / 'Sources/TurtleGitCore/Resources/Icons/provenance.json').read_text())
for asset in manifest['assets']:
    assert hashlib.sha256((icons / asset['asset']).read_bytes()).hexdigest() == asset['sha256'], asset['asset']
assert (icons / 'UPSTREAM-ICON-LICENSE.txt').is_file()
completion = framework / 'Resources/Completion'
completion_manifest = json.loads((root / 'Sources/TurtleGitCore/Resources/Completion/provenance.json').read_text())
assert json.loads((completion / 'provenance.json').read_text()) == completion_manifest
for asset in completion_manifest['assets']:
    assert hashlib.sha256((completion / asset['asset']).read_bytes()).hexdigest() == asset['sha256'], asset['asset']
extension = app / 'Contents/PlugIns/TurtleGitFinder.appex'
with (extension / 'Contents/Info.plist').open('rb') as stream:
    finder = plistlib.load(stream)
assert finder['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.FinderSync'
assert (extension / 'Contents/MacOS' / finder['CFBundleExecutable']).is_file()
print(f'App, embedded Finder extension, licenses and all {len(manifest["assets"])} upstream icon resources verified.')

if args.require_git:
    import subprocess
    subprocess.run(['/usr/bin/python3', str(root / 'scripts/validate-git-runtime.py'), str(app / 'Contents/Helpers/Git')], check=True)

import subprocess
subprocess.run(['/usr/bin/python3', str(root / 'scripts/validate-editorconfig-runtime.py'), str(app / 'Contents/Helpers/EditorConfig')], check=True)
subprocess.run(['/usr/bin/python3', str(root / 'scripts/validate-issue-regex-runtime.py'), str(app / 'Contents/Helpers/IssueRegex')], check=True)
