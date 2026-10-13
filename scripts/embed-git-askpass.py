#!/usr/bin/env python3
"""Embed the native Git authentication dialog; never handles credential data."""
from runtime_bundle_layout import remove_entry
import os
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

source, app = map(Path, sys.argv[1:])
if not source.is_file():
    raise SystemExit('Git askpass helper build product is missing.')
destination = app / 'Contents/Helpers/GitAskpass/TurtleGitGitAskpass'
if destination.parent.is_symlink(): remove_entry(destination.parent)
destination.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(source, destination)
destination.chmod(0o755)
if os.environ.get('CODE_SIGNING_ALLOWED') == 'YES':
    identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY')
    if not identity:
        raise SystemExit('Git askpass signing identity is unavailable.')
    command = ['/usr/bin/codesign', '--force', '--sign', identity, '--options', 'runtime']
    if os.environ.get('CONFIGURATION') == 'AppStore':
        command += ['--entitlements', str(Path(__file__).resolve().parent.parent / 'Configuration/GitHelper.entitlements')]
    subprocess.run(command + [str(destination)], check=True)
root = Path(__file__).resolve().parent.parent
manifest = {'binary_sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
            'sources': {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in [root/'Sources/TurtleGitCore/GitAskpassPrompt.swift', root/'Sources/TurtleGitMac/DocumentationCapture.swift', *sorted((root/'Sources/TurtleGitGitAskpass').glob('*.swift'))]},
            'sandbox_inherited': os.environ.get('CODE_SIGNING_ALLOWED') == 'YES' and os.environ.get('CONFIGURATION') == 'AppStore'}
(destination.parent/'provenance.json').write_text(json.dumps(manifest, indent=2)+'\n')
print('Git askpass helper embedded; signed sandbox acceptance remains separate.')
