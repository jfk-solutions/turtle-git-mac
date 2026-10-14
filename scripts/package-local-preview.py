#!/usr/bin/env python3
"""Package an audited Release app as a local ad-hoc preview; never install or upload."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from preview_signing import signing_plan

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--audit', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
audit = json.loads(args.audit.read_text())
if audit.get('kind') != 'TurtleGitUnsignedDistributionAudit' or audit.get('configuration') != 'Release':
    raise SystemExit('Use a successful Release build-distribution.py audit.')
source = Path(audit['app']).resolve(strict=True)
for name, expected in audit['code_sha256'].items():
    if hashlib.sha256((source / name).read_bytes()).hexdigest() != expected:
        raise SystemExit('Release code changed since its audit: ' + name)
layout = json.loads((source / 'Contents/Resources/runtime-layout.json').read_text())
if any(item['sandbox_inherited'] for item in layout['code'].values()):
    raise SystemExit('Inherited sandbox runtimes require a properly signed distribution, not a local preview.')
output = args.output.absolute()
if output.exists() or output.is_symlink():
    raise SystemExit('Choose a fresh output directory; existing previews are never replaced.')
output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='.TurtleGitPreview-', dir=output.parent) as temporary:
    package = Path(temporary) / output.name
    package.mkdir()
    app = package / 'TurtleGitMac.app'
    subprocess.run(['/usr/bin/ditto', str(source), str(app)], check=True)
    runtime_code = {item['destination'] for item in layout['code'].values()}
    payloads, bundles = signing_plan(app, runtime_code)
    for path in [*payloads, *bundles]:
        subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    subprocess.run([sys.executable, str(ROOT / 'scripts/validate-app-bundle.py'), str(app), '--require-git', '--require-universal'], check=True)
    subprocess.run([sys.executable, str(ROOT / 'scripts/audit-cache-service.py'), str(app)], check=True)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    archive = package / ('TurtleGit-for-Mac-' + version + '-local-preview.zip')
    subprocess.run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)], check=True)
    roundtrip = Path(temporary) / 'roundtrip'
    subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), str(roundtrip)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(roundtrip / app.name)], check=True)
    shutil.rmtree(roundtrip)
    hasher = hashlib.sha256()
    with archive.open('rb') as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            hasher.update(chunk)
    digest = hasher.hexdigest()
    (package / 'SHA256SUMS').write_text(digest + '  ' + archive.name + '\n')
    for filename in ['LICENSE', 'NOTICE']:
        shutil.copy2(ROOT / filename, package / filename)
    (package / 'START-HERE.txt').write_text(
        'TurtleGit for Mac ' + version + ' — local preview\n\n'
        'A macOS fork of TortoiseGit. The complete port is still in progress.\n\n'
        'The app contains Apple Silicon and Intel code and its Git/runtime helpers.\n'
        'Use either the app here or extract the ZIP. To keep it, copy TurtleGitMac.app\n'
        'into Applications, then open it and choose a repository folder.\n'
        'Enable the TurtleGit Finder extension in macOS System Settings if desired.\n'
        'No app, Finder extension, cache service or login item was installed or\n'
        'activated by the packaging script.\n\n'
        'This copy has a local ad-hoc code seal. It is not Developer ID signed,\n'
        'notarized, or an App Store submission. macOS may require explicit approval\n'
        'to open it. Signed Finder/sandbox behavior and full dialog parity are not\n'
        'certified. Try a disposable repository before using it for important work.\n\n'
        'Documentation: https://jfk-solutions.github.io/turtle-git-mac/\n'
        'Source: https://github.com/jfk-solutions/turtle-git-mac\n'
        'See LICENSE, NOTICE, preview-manifest.json and SHA256SUMS.\n')
    record = {
        'kind': 'TurtleGitLocalPreview', 'created_at': datetime.now(timezone.utc).isoformat(),
        'version': version, 'build': info['CFBundleVersion'],
        'workspace_commit_at_packaging': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'source_audit': audit, 'zip': archive.name, 'sha256': digest,
        'code_seal': 'ad-hoc; deep strict verification passed on app and extracted ZIP',
        'universal_bundle_and_cache_layout': 'passed',
        'launch_and_physical_Finder_acceptance': 'not performed',
        'developer_id_notarization_app_store': 'not performed',
    }
    (package / 'preview-manifest.json').write_text(json.dumps(record, indent=2) + '\n')
    package.rename(output)
print('Local preview:', output)
print('No installation, GUI launch, registration, upload or submission was performed.')
