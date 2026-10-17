#!/usr/bin/env python3
"""Build/audit an unsigned universal XCArchive; optionally prepare offline export settings."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import subprocess
import sys
from distribution_archive import KIND, archive_application, debug_symbols, file_inventory, export_options
from bundle_architectures import audit_application_architectures
from distribution_provenance import source_inputs, require_same_inputs, require_same_bundle

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--configuration', choices=('AppStore','Release'), default='AppStore')
parser.add_argument('--archive-path', type=Path, required=True)
parser.add_argument('--derived-data', type=Path, default=ROOT/'build-archive')
parser.add_argument('--audit-existing', action='store_true')
parser.add_argument('--team-id', help='Prepare ExportOptions.plist for an actual team; does not sign or export.')
args = parser.parse_args()
archive = args.archive_path.absolute()
if archive.suffix != '.xcarchive' or archive.is_symlink(): raise SystemExit('Use a nonsymlink .xcarchive destination.')
report = archive.with_suffix('.archive-audit.json')
options_path = archive.with_suffix('.ExportOptions.plist')
previous = None
if report.exists():
    previous = json.loads(report.read_text())
    if previous.get('kind') != KIND: raise SystemExit('Refusing to replace an unrelated archive report.')
    report.unlink()
if not args.audit_existing and archive.exists():
    raise SystemExit('Archive already exists; use --audit-existing or choose a fresh destination.')
options = export_options(args.configuration,args.team_id) if args.team_id else None
if options and options_path.exists():
    if options_path.is_symlink() or plistlib.loads(options_path.read_bytes()) != options:
        raise SystemExit('Refusing to replace different or unrelated export settings.')
if args.audit_existing:
    if previous is None or previous.get('configuration') != args.configuration or Path(previous.get('archive', '')).resolve() != archive.resolve():
        raise SystemExit('Rebuild once, or supply the original audit for this archive/configuration.')
    require_same_inputs(previous.get('build_inputs'), source_inputs(ROOT))
    require_same_bundle(previous.get('files'), archive)
    measured_inputs = previous['build_inputs']
else:
    measured_inputs = source_inputs(ROOT)
    archive.parent.mkdir(parents=True,exist_ok=True)
    scheme = 'TurtleGitAppStore' if args.configuration == 'AppStore' else 'TurtleGitMac'
    subprocess.run(['xcodebuild','-quiet','-project',str(ROOT/'TurtleGitMac.xcodeproj'),'-scheme',scheme,
                    '-configuration',args.configuration,'-destination','generic/platform=macOS',
                    '-derivedDataPath',str(args.derived_data.resolve()),'-archivePath',str(archive),
                    'CODE_SIGNING_ALLOWED=NO','archive'],cwd=ROOT,check=True)
require_same_inputs(measured_inputs, source_inputs(ROOT))
app,metadata,info = archive_application(archive)
subprocess.run([sys.executable,str(ROOT/'scripts/validate-app-bundle.py'),str(app),'--require-git','--require-universal'],cwd=ROOT,check=True)
subprocess.run([sys.executable,str(ROOT/'scripts/audit-cache-service.py'),str(app)],cwd=ROOT,check=True)
architectures = audit_application_architectures(app)
symbols = debug_symbols(archive,app)
inventory = file_inventory(archive)
record = {'kind':KIND,'configuration':args.configuration,'archive':str(archive),'app':str(app),
          'checked_at':datetime.now(timezone.utc).isoformat(),'bundle_identifier':info['CFBundleIdentifier'],
          'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],
          'architectures':architectures,'debug_symbols':symbols,'files':inventory,
          'build_inputs':measured_inputs,
          'audited_git_head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
          'signing_and_sandbox_acceptance':'unverified','submission':'not performed',
          'export':'not performed','export_settings':str(options_path) if options else None}
if options:
    options_path.write_bytes(plistlib.dumps(options,sort_keys=True))
require_same_inputs(measured_inputs, source_inputs(ROOT))
report.write_text(json.dumps(record,indent=2)+'\n')
print('Unsigned universal archive, package and matching dSYMs audited:',archive)
print('Report:',report)
if options: print('Offline export settings prepared:',options_path)
