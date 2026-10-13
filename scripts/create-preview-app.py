#!/usr/bin/env python3
"""Make an independent ad-hoc-signed Debug app for documentation; never replace the user's running app."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import shutil
import subprocess
import urllib.parse

parser = argparse.ArgumentParser()
parser.add_argument('source', type=pathlib.Path)
parser.add_argument('destination', type=pathlib.Path)
parser.add_argument('--repository', required=True, type=pathlib.Path)
parser.add_argument('--swift-executable', type=pathlib.Path, help='Use a Swift Package Debug executable when Xcode is unavailable.')
parser.add_argument('--bundle-identifier', default='org.turtlegit.macos.documentation-preview')
parser.add_argument('--name', default='TurtleGit Documentation Preview')
parser.add_argument('--screenshot', type=pathlib.Path, help='Debug-only destination for the Save Window Screenshot command.')
parser.add_argument('--appearance', choices=['system', 'light', 'dark'], help='Debug-only initial appearance.')
parser.add_argument('--resource-runtimes', action='store_true', help='Upgrade an older Debug runtime layout before signing the preview.')
parser.add_argument('--finder-request', help='Debug-only Finder request dispatched after the demo repository opens.')
args = parser.parse_args()
if args.destination.exists():
    raise SystemExit('Preview destination already exists. Choose another path.')
if not (args.repository / '.git').exists() and not all((args.repository / name).exists() for name in ('HEAD', 'objects', 'config')):
    raise SystemExit('Use a disposable demo repository created with create-demo-repository.py.')
if args.finder_request:
    request = urllib.parse.urlparse(args.finder_request)
    fields = urllib.parse.parse_qs(request.query, keep_blank_values=True)
    if request.scheme != 'turtlegit' or request.netloc != 'action' or len(fields.get('command', [])) != 1 or not fields.get('path') or not all(path.startswith('/') and '\0' not in path for path in fields['path']):
        raise SystemExit('Use a valid turtlegit://action Finder request with absolute paths.')
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
if args.finder_request:
    data['TurtleGitDocumentationRequest'] = args.finder_request
else:
    data.pop('TurtleGitDocumentationRequest', None)
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

layout = args.destination / 'Contents/Resources/runtime-layout.json'
if layout.is_file():
    from runtime_bundle_layout import audit_layout
    descriptor=json.loads(layout.read_text())
    if any(record['sandbox_inherited'] for record in descriptor['code'].values()):
        raise SystemExit('Use a Debug build for an ad-hoc documentation preview.')
    audit_layout(args.destination)
elif args.resource_runtimes:
    # Older Debug bundles can be upgraded using the same production layout.
    import os
    environment=dict(os.environ,CODE_SIGNING_ALLOWED='NO')
    subprocess.run(['/usr/bin/python3',str(pathlib.Path(__file__).with_name('finalize-runtime-layout.py')),str(args.destination)],env=environment,check=True)

# A replaced executable invalidates the copied bundle signature. Keep Swift resources
# inside Contents/Resources so the preview passes bundle signature validation.
legacy_resources = args.destination / 'TurtleGitMac_TurtleGitCore.bundle'
if legacy_resources.exists():
    shutil.rmtree(legacy_resources)
# Sign actual payloads explicitly. --deep guesses bundle structure from data
# directories (including versioned Perl libraries) and can reject valid runtimes.
magic = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
runtime_code = {record['destination'] for record in json.loads(layout.read_text())['code'].values()} if layout.is_file() else set()
for path in sorted(args.destination.rglob('*')):
    if path.is_relative_to(args.destination / 'Contents') and str(path.relative_to(args.destination / 'Contents')) in runtime_code:
        continue # Finalization already signed these payloads and bound their hashes.
    if path.is_file() and not path.is_symlink() and 'MacOS' not in path.parts and not any(part.endswith('.framework') for part in path.parts):
        with path.open('rb') as stream:
            is_code = stream.read(4) in magic
        if is_code:
            subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True)
bundles = [path for path in args.destination.rglob('*') if path.is_dir() and not path.is_symlink() and path.suffix in ('.framework', '.appex', '.app')]
for bundle in sorted(bundles, key=lambda path: len(path.parts), reverse=True):
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(args.destination)], check=True)
# Signing changes the bundled parser bytes. Update its provenance and
# then reseal only the containing app so the helper signature stays intact.
for helper, executable_name in ([] if layout.is_file() else [('EditorConfig', 'editorconfig'), ('IssueRegex', 'issue-regex'), ('MergeDiff', 'merge-diff')]):
    parser_runtime = args.destination / 'Contents/Helpers' / helper
    if not parser_runtime.is_dir():
        continue
    manifest_path = parser_runtime / 'provenance.json'
    manifest = json.loads(manifest_path.read_text())
    manifest.setdefault('unsigned_binary_sha256', manifest['binary_sha256'])
    manifest['binary_sha256'] = hashlib.sha256((parser_runtime / executable_name).read_bytes()).hexdigest()
    manifest['signed'] = True
    manifest['sandbox_inherited'] = False  # This script creates Debug previews.
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
subprocess.run(['codesign', '--force', '--sign', '-', str(args.destination)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.destination)], check=True)

print(args.destination.resolve())
