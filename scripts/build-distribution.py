#!/usr/bin/env python3
"""Build and audit an unsigned universal distribution candidate; never publish it."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from datetime import datetime, timezone
from bundle_architectures import audit_application_architectures

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--configuration', choices=('AppStore','Release'), default='AppStore')
parser.add_argument('--derived-data', type=Path, default=ROOT / 'build-distribution')
parser.add_argument('--audit-existing', action='store_true', help='Audit an already built candidate without rebuilding.')
args = parser.parse_args()
derived = args.derived_data.resolve()
app = derived / 'Build/Products' / args.configuration / 'TurtleGitMac.app'
report = derived / 'distribution-audit.json'
# This path is owned by this tool, and a failed run must not retain an old success.
if report.exists():
    previous = json.loads(report.read_text())
    if previous.get('kind') != 'TurtleGitUnsignedDistributionAudit':
        raise SystemExit('Refusing to replace an unrelated distribution-audit.json')
    report.unlink()
if not args.audit_existing:
    scheme = 'TurtleGitAppStore' if args.configuration == 'AppStore' else 'TurtleGitMac'
    subprocess.run(['xcodebuild','-project',str(ROOT/'TurtleGitMac.xcodeproj'),'-scheme',scheme,
                    '-configuration',args.configuration,'-destination','generic/platform=macOS',
                    '-derivedDataPath',str(derived),'CODE_SIGNING_ALLOWED=NO','build'],cwd=ROOT,check=True)
subprocess.run([sys.executable,str(ROOT/'scripts/validate-app-bundle.py'),str(app),'--require-git','--require-universal'],cwd=ROOT,check=True)
subprocess.run([sys.executable,str(ROOT/'scripts/audit-cache-service.py'),str(app)],cwd=ROOT,check=True)
slices = audit_application_architectures(app)
record = {'kind':'TurtleGitUnsignedDistributionAudit','configuration':args.configuration,
          'app':str(app),'checked_at':datetime.now(timezone.utc).isoformat(),
          'architectures':slices,
          'code_sha256':{name:hashlib.sha256((app/name).read_bytes()).hexdigest() for name in slices},
          'signing_and_sandbox_acceptance':'unverified','app_store_submission':'not performed'}
report.write_text(json.dumps(record,indent=2)+'\n')
print('Unsigned universal package audited:', app)
print('Report:', report)
