#!/usr/bin/env python3
"""Hidden native Send Patch dialog/model verification. Private loopback SMTP only; no real mail service/Keychain."""
from native_receiver import build_receiver, run_receiver
from pathlib import Path
import os
import json
import base64
import time
import platform
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-send-patch-dialog-native-') as temporary:
    directory = Path(temporary)
    executable = build_receiver(root, [root / 'docs/qa/send-patch-dialog-native-2026-10-10.swift'], directory)
    fixture = directory / 'fixture'; fixture.mkdir()
    environment = os.environ.copy(); environment['DYLD_FRAMEWORK_PATH'] = str(products)
    environment.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='', GIT_AUTHOR_EMAIL='')
    server = subprocess.Popen(['/usr/bin/python3', str(root / 'Tests/TurtleGitCoreTests/Fixtures/smtp_server.py'), str(fixture), 'normal', '60'])
    try:
        ready = fixture / 'ready.json'; deadline = time.monotonic() + 10
        while not ready.exists() and server.poll() is None and time.monotonic() < deadline: time.sleep(.01)
        port = json.loads(ready.read_text())['port']
        run_receiver([str(executable), str(fixture), str(port)], cwd=root, env=environment, check=True, timeout=90)
        assert server.wait(timeout=10) == 0
        state = json.loads((fixture / 'result.json').read_text())
        assert state['accepted'] == 1 and state['auth'] == 0 and state['data'] == 1
        assert state['recipients'] == ['RCPT TO:<to@example.invalid>', 'RCPT TO:<cc@example.invalid>']
        assert len(state['parts']) == 3
        assert base64.b64decode(state['parts'][0]['payload']) == (fixture / 'expected-body').read_bytes()
        for part in state['parts'][1:]:
            assert part['filename'] == '2.patch'
            assert base64.b64decode(part['payload']) == (fixture / 'expected-attachment').read_bytes()
        print('Production configured-entry Git sender/SDK SMTP loopback and independent MIME decoding passed; owned server/fixtures cleaned.')
    finally:
        if server.poll() is None: server.terminate()
        server.wait(timeout=10)
