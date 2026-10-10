#!/usr/bin/env python3
"""Check ordinary/Store helper signing branches in disposable ad-hoc bundles."""
import hashlib
import json
import os
import pathlib
import plistlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
runtime = ROOT / 'build/graph-layout-runtime/GraphLayout'
original = hashlib.sha256((runtime / 'graph-layout').read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(prefix='turtlegit-graph-embedding-') as temporary:
    for configuration in ['Debug', 'AppStore']:
        app = pathlib.Path(temporary) / (configuration + '.app')
        (app / 'Contents').mkdir(parents=True)
        environment = dict(os.environ, CODE_SIGNING_ALLOWED='YES', EXPANDED_CODE_SIGN_IDENTITY='-', CONFIGURATION=configuration)
        subprocess.run(['python3', str(ROOT / 'scripts/embed-graph-layout-runtime.py'), str(runtime), str(app)], env=environment, check=True)
        helper = app / 'Contents/Helpers/GraphLayout/graph-layout'
        subprocess.run(['codesign', '--verify', '--strict', str(helper)], check=True)
        display = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(helper)], capture_output=True, check=True)
        manifest = json.loads((helper.parent / 'provenance.json').read_text())
        assert manifest['signed'] and manifest['unsigned_binary_sha256'] == original
        assert manifest['binary_sha256'] == hashlib.sha256(helper.read_bytes()).hexdigest()
        assert manifest['sandbox_inherited'] == (configuration == 'AppStore')
        if configuration == 'AppStore':
            entitlements = plistlib.loads(display.stdout)
            assert entitlements.get('com.apple.security.app-sandbox') is True
            assert entitlements.get('com.apple.security.inherit') is True
        else:
            assert b'com.apple.security.app-sandbox' not in display.stdout
assert hashlib.sha256((runtime / 'graph-layout').read_bytes()).hexdigest() == original
print('GraphLayout ordinary and AppStore ad-hoc helper signatures, entitlement branches, provenance updates and disposable cleanup passed. Signed app sandbox acceptance remains pending.')
