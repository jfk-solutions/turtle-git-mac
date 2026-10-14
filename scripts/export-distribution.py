#!/usr/bin/env python3
"""Export a signed archive locally and audit its package; never upload or submit."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
from distribution_archive import archive_application, export_options

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--archive-path', type=Path, required=True)
parser.add_argument('--options', type=Path, required=True)
parser.add_argument('--export-path', type=Path, required=True)
args = parser.parse_args()
archive = args.archive_path.resolve(strict=True)
app, metadata, info = archive_application(archive)
if args.options.is_symlink(): raise SystemExit('Export settings must not be a symlink.')
options = plistlib.loads(args.options.read_bytes())
channel = 'AppStore' if options.get('method') == 'app-store-connect' else 'Release' if options.get('method') == 'developer-id' else None
if channel is None or options != export_options(channel,options.get('teamID')):
    raise SystemExit('Use the generated offline export settings; upload/custom export modes are refused.')
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
identity = subprocess.run(['codesign','-dvv',str(app)],capture_output=True,text=True,check=True).stderr
team = re.search(r'^TeamIdentifier=(.+)$',identity,re.MULTILINE)
if 'Signature=adhoc' in identity or not team or team.group(1) != options['teamID']:
    raise SystemExit('Archive must already be signed by the selected team; unsigned/ad-hoc candidates cannot export.')
output = args.export_path.absolute()
if output.exists() or output.is_symlink(): raise SystemExit('Choose a fresh export directory; existing output is never replaced.')
output.parent.mkdir(parents=True,exist_ok=True)
# Keep failed Xcode output outside the requested successful package directory.
with tempfile.TemporaryDirectory(prefix='TurtleGitExport-',dir=output.parent) as temporary:
    staging = Path(temporary)/'export'
    subprocess.run(['xcodebuild','-exportArchive','-archivePath',str(archive),'-exportPath',str(staging),'-exportOptionsPlist',str(args.options.resolve())],cwd=ROOT,check=True)
    packages = list(staging.glob('*.pkg'))
    apps = list(staging.glob('*.app'))
    if channel == 'AppStore':
        if len(packages) != 1 or apps: raise SystemExit('Expected one App Store installer package.')
        signature = subprocess.run(['pkgutil','--check-signature',str(packages[0])],capture_output=True,text=True,check=True).stdout
        if '('+options['teamID']+')' not in signature: raise SystemExit('Installer package signature does not identify the selected team.')
        expanded = Path(temporary)/'expanded'
        subprocess.run(['pkgutil','--expand-full',str(packages[0]),str(expanded)],check=True)
        apps = [p for p in expanded.rglob('*.app') if not any(parent.suffix == '.app' for parent in p.parents) and (p/'Contents/Info.plist').is_file()]
    if len(apps) != 1: raise SystemExit('Export does not contain exactly one top-level application.')
    exported = apps[0]
    actual = plistlib.loads((exported/'Contents/Info.plist').read_bytes())
    for key in ['CFBundleIdentifier','CFBundleVersion','CFBundleShortVersionString']:
        if actual.get(key) != info.get(key): raise SystemExit('Export changed reviewed application identity: '+key)
    subprocess.run(['codesign','--verify','--deep','--strict',str(exported)],check=True)
    subprocess.run([sys.executable,str(ROOT/'scripts/validate-app-bundle.py'),str(exported),'--require-git','--require-universal'],cwd=ROOT,check=True)
    subprocess.run([sys.executable,str(ROOT/'scripts/audit-cache-service.py'),str(exported)],cwd=ROOT,check=True)
    record = {'kind':'TurtleGitOfflineExportAudit','archive':str(archive),'team_id':options['teamID'],'channel':channel,
              'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'signatures_and_unsigned_package_audits':'passed',
              'signed_runtime_and_sandbox_acceptance':'unverified','app_store_submission':'not performed','upload':'not performed'}
    (staging/'export-audit.json').write_text(json.dumps(record,indent=2)+'\n')
    staging.rename(output)
print('Local exported package audited:',output)
print('No upload, notarization or App Store submission was performed.')
