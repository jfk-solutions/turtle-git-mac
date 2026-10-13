#!/usr/bin/env python3
"""Embed native WCRev code in MacOS and provenance data in Resources."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

source, app = map(Path, sys.argv[1:])
if not source.is_file():
    raise SystemExit('Working copy revision tool build product is missing')
root = Path(__file__).resolve().parent.parent
destination = app / 'Contents/MacOS/TurtleGitWCRev'
if destination.is_symlink(): destination.unlink()
shutil.copy2(source, destination)
destination.chmod(0o755)
if os.environ.get('CODE_SIGNING_ALLOWED') == 'YES':
    identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY')
    if not identity: raise SystemExit('WCRev signing identity is unavailable')
    command = ['/usr/bin/codesign', '--force', '--sign', identity, '--options', 'runtime']
    if os.environ.get('CONFIGURATION') == 'AppStore':
        command += ['--entitlements', str(root/'Configuration/GitHelper.entitlements')]
    subprocess.run(command + [str(destination)], check=True)
manifest = {'binary_sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
            'sources': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [root/'Sources/TurtleGitCore/WorkingCopyRevision.swift', root/'Sources/TurtleGitWCRev/TurtleGitWCRev.swift']},
            'sandbox_inherited': os.environ.get('CODE_SIGNING_ALLOWED') == 'YES' and os.environ.get('CONFIGURATION') == 'AppStore'}
resources = app/'Contents/Resources'
resources.mkdir(parents=True, exist_ok=True)
(resources/'wcrev-provenance.json').write_text(json.dumps(manifest, indent=2)+'\n')
print('Working copy revision utility embedded; signed sandbox execution remains separate')
