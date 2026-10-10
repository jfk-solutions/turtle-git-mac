#!/usr/bin/env python3
"""Exercise actual built Core/SMTP frameworks; private loopback SMTP, plus optional read-only DNS probe."""
from pathlib import Path
import base64
import json
import os
import platform
import subprocess
import tempfile
import time
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-configured-smtp-native-') as temporary:
    folder = Path(temporary); fixture = folder / 'fixture'; fixture.mkdir()
    executable = folder / 'configured-smtp-native-receiver'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-target', platform.machine() + '-apple-macos13.0',
                    '-I', str(products), '-F', str(products), str(root / 'docs/qa/send-patch-smtp-native-2026-10-10.swift'),
                    '-framework', 'TurtleGitCore', '-o', str(executable)], cwd=root, check=True)
    server = subprocess.Popen(['/usr/bin/python3', str(root / 'Tests/TurtleGitCoreTests/Fixtures/smtp_server.py'), str(fixture), 'normal'])
    try:
        deadline = time.monotonic() + 10
        ready = fixture / 'ready.json'
        while not ready.exists() and server.poll() is None and time.monotonic() < deadline: time.sleep(.01)
        port = json.loads(ready.read_text())['port']
        environment = os.environ.copy(); environment['DYLD_FRAMEWORK_PATH'] = str(products)
        subprocess.run([str(executable), str(fixture), str(port)], env=environment, cwd=root, check=True)
        assert server.wait(timeout=10) == 0
        state = json.loads((fixture / 'result.json').read_text())
        assert state['accepted'] == 1 and state['data'] == 1 and state['auth'] == 0
        assert state['recipients'] == ['RCPT TO:<to@example.invalid>', 'RCPT TO:<review@example.invalid>']
        assert (fixture / 'message.eml').read_bytes() == (fixture / 'expected.eml').read_bytes()
        assert len(state['parts']) == 3
        assert base64.b64decode(state['parts'][1]['payload']).endswith(bytes([0, 255, 128]))
        print('SDK framework loopback MIME bytes, independent decoder and binary attachment retention passed; private server/fixture cleaned.')
    finally:
        if server.poll() is None: server.terminate()
        server.wait(timeout=10)
