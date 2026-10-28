#!/usr/bin/env python3
"""Private real HTTP native issue-provider Settings, picker and Commit workflows."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import uuid
from native_receiver import build_receiver, run_receiver


class ProviderServer(ThreadingHTTPServer):
    daemon_threads = False
    block_on_close = True
    def __init__(self, control, receipts, token):
        self.control = control
        self.receipts = receipts
        self.token = token
        self.stopping = threading.Event()
        self.log_lock = threading.Lock()
        super().__init__(('127.0.0.1', 0), ProviderHandler)
    def state(self):
        return json.loads(self.control.read_text())
    def record(self, value):
        with self.log_lock:
            with self.receipts.open('a') as output:
                output.write(json.dumps(value, ensure_ascii=False) + '\n')


class ProviderHandler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(5)
    def log_message(self, *args):
        pass
    def do_POST(self):
        length = int(self.headers.get('Content-Length', '0'))
        if length <= 0 or length > 1048576:
            self.send_error(413)
            return
        request = json.loads(self.rfile.read(length))
        authorized = self.headers.get('Authorization') == 'Bearer ' + self.server.token
        # Credentials never enter the receipts; only the exact protocol context
        # and a boolean proving actual HTTP header authentication are retained.
        self.server.record({'authorized': authorized, 'body': request})
        action = request.get('action')
        while not self.server.stopping.is_set() and self.server.state().get('holdAction') == action:
            self.server.stopping.wait(.01)
        state = self.server.state()
        response = {'version': 1}
        status = 200
        if not authorized:
            status = 401
            response['error'] = 'Missing private bearer credential'
        elif request.get('version') != 1:
            response['error'] = 'Unsupported private protocol version'
        elif action == 'listIssues':
            response['issues'] = [{'id': '17', 'summary': 'Snow issue 雪'}, {'id': '42', 'summary': 'Forty two'}]
        elif action == 'commitMessage':
            if state.get('messageError'):
                response['error'] = 'Private message preparation failed'
            selected = request.get('selectedIDs', [])
            issue_id = ','.join(selected)
            response['message'] = request['context']['message'] + '\nProvider issues: ' + issue_id + '\n'
            if not state.get('omitIssueID'):
                response['issueID'] = issue_id
        elif action == 'checkCommit':
            if state.get('rejectCheck'):
                response['error'] = 'Provider requires review before commit'
            if state.get('checkHTTPStatus'):
                status = state['checkHTTPStatus']
        elif action == 'commitFinished':
            if state.get('finishHTTPStatus'):
                status = state['finishHTTPStatus']
            if state.get('finishWarning'):
                response['warning'] = state['finishWarning']
        else:
            response['error'] = 'Unknown private action'
        payload = b'{invalid-json' if action == 'checkCommit' and state.get('malformedCheck') else json.dumps(response, ensure_ascii=False).encode()
        try:
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=['settings', 'commit', 'lifetime', 'check-failure'], action='append')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='turtlegit-native-issue-provider-') as temporary:
    directory = Path(temporary)
    receiver = build_receiver(root, [root / 'docs/qa/native-issue-provider-2026-10-20.swift'], directory)
    for case in args.only or ['settings', 'commit', 'lifetime', 'check-failure']:
        for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
            context = directory / (case + str(index)); context.mkdir(mode=0o700)
            fixture = context / 'fixture'; fixture.mkdir(mode=0o700)
            private_tmp = context / 'temporary'; private_tmp.mkdir(mode=0o700)
            preferences = context / 'preferences'; preferences.mkdir(mode=0o700)
            xdg = context / 'xdg'; xdg.mkdir(mode=0o700)
            config = context / 'global.config'; config.write_text('')
            control = context / 'control.json'; control.write_text('{}')
            receipts = context / 'requests.jsonl'; receipts.write_text('')
            token = 'private-provider-token-' + uuid.uuid4().hex
            server = ProviderServer(control, receipts, token)
            thread = threading.Thread(target=server.serve_forever, name='private-provider-http', daemon=False)
            thread.start()
            endpoint = 'http://127.0.0.1:' + str(server.server_address[1]) + '/api'
            env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            env.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0',
                       CFFIXED_USER_HOME=str(preferences), XDG_CONFIG_HOME=str(xdg), TMPDIR=str(private_tmp) + '/',
                       DYLD_FRAMEWORK_PATH=str(root / 'build/Build/Products/Debug'),
                       TURTLEGIT_NATIVE_PROVIDER_CASE=case, TURTLEGIT_PRIVATE_PROVIDER_TOKEN=token)
            print('Checking native issue provider ' + case + ' with ' + str(git), flush=True)
            try:
                result = run_receiver([str(receiver), str(fixture), str(git.absolute()), endpoint, str(control), str(receipts)],
                                      cwd=root, env=env, capture_output=True, text=True, timeout_sample=context / 'timeout.sample.txt')
                print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
                if 'PASS: native issue provider case completed' not in result.stdout:
                    raise SystemExit('Native provider receiver exited before completion')
            finally:
                server.stopping.set(); server.shutdown(); server.server_close(); thread.join(timeout=5)
                if thread.is_alive():
                    raise RuntimeError('Private provider HTTP server did not terminate')
