#!/usr/bin/env python3
"""Private smart-HTTP Git fixture with TLS and Basic authentication, never public mail/network."""
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import ssl
import subprocess
import sys
import threading
from urllib.parse import urlsplit

root, git, repository = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
lock = threading.RLock()
state = {'requests': [], 'tls_failures': 0}
children = set()
stopping = threading.Event()

def publish():
    with lock:
        temporary = root / 'state.json.tmp'
        temporary.write_text(json.dumps(state), encoding='utf-8')
        temporary.replace(root / 'state.json')

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args):
        pass
    def do_GET(self):
        self.respond()
    def do_POST(self):
        self.respond()
    def respond(self):
        length = int(self.headers.get('Content-Length', '0'))
        if length < 0 or length > 16 * 1024 * 1024:
            self.send_error(413)
            return
        parts = urlsplit(self.path)
        expected = 'Basic ' + base64.b64encode(b'fixture-user:fixture-password').decode('ascii')
        authenticated = self.headers.get('Authorization') == expected
        record = {'method': self.command, 'path': self.path, 'authenticated': authenticated,
                  'body_bytes': length, 'fixture_header': self.headers.get('X-TurtleGit-Fixture') == 'private-fixture'}
        with lock:
            state['requests'].append(record)
            publish()
        redirect = root / 'redirect.json'
        if redirect.is_file():
            rule = json.loads(redirect.read_text())
            if not rule.get('require_auth', False) or authenticated:
                self.send_response(307)
                self.send_header('Location', rule['location'] + self.path[len('/repo.git'):])
                self.send_header('Content-Length', '0')
                self.send_header('Connection', 'close')
                self.end_headers()
                self.close_connection = True
                return
        if not authenticated:
            self.send_response(401)
            self.send_header('WWW-Authenticate', 'Basic realm="TurtleGit private Git fixture"')
            self.send_header('Content-Length', '0')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.close_connection = True
            return
        if not parts.path.startswith('/repo.git/'):
            self.send_error(404)
            return
        if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
            body = bytearray()
            while True:
                chunk_line = self.rfile.readline(4096)
                size = int(chunk_line.split(b';', 1)[0].strip(), 16)
                if size < 0 or len(body) + size > 16 * 1024 * 1024:
                    self.send_error(413)
                    return
                if size == 0:
                    while self.rfile.readline(4096).strip():
                        pass
                    break
                chunk = self.rfile.read(size)
                if len(chunk) != size or self.rfile.read(2) != b'\r\n':
                    self.send_error(400)
                    return
                body.extend(chunk)
            body = bytes(body)
        else:
            body = self.rfile.read(length)
        with lock:
            record['body_bytes'] = len(body)
            publish()
        environment = dict(os.environ, GIT_PROJECT_ROOT=str(repository.parent), GIT_HTTP_EXPORT_ALL='1',
                           REQUEST_METHOD=self.command, PATH_INFO='/' + repository.name + parts.path[len('/repo.git'):],
                           QUERY_STRING=parts.query, CONTENT_TYPE=self.headers.get('Content-Type', ''),
                           CONTENT_LENGTH=str(len(body)), HTTP_CONTENT_ENCODING=self.headers.get('Content-Encoding', ''), REMOTE_USER='fixture-user', REMOTE_ADDR='127.0.0.1')
        if self.headers.get('Git-Protocol'):
            environment['HTTP_GIT_PROTOCOL'] = self.headers['Git-Protocol']
        with lock:
            if stopping.is_set():
                return
            process = subprocess.Popen([str(git), 'http-backend'], stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       env=environment, start_new_session=True)
            children.add(process)
        try:
            try:
                output, diagnostic = process.communicate(input=body, timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                output, diagnostic = process.communicate()
        finally:
            with lock:
                children.discard(process)
        if process.returncode:
            self.send_error(502)
            return
        header, separator, payload = output.partition(b'\r\n\r\n')
        if not separator:
            header, separator, payload = output.partition(b'\n\n')
        if not separator:
            self.send_error(502)
            return
        headers = []
        status = 200
        for line in header.decode('latin-1').splitlines():
            key, value = line.split(':', 1)
            if key.lower() == 'status':
                status = int(value.strip().split()[0])
            elif key.lower() not in ('content-length', 'connection'):
                headers.append((key, value.strip()))
        self.send_response(status)
        for key, value in headers:
            self.send_header(key, value)
        self.send_header('Content-Length', str(len(payload)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

class Server(ThreadingHTTPServer):
    daemon_threads = False
    block_on_close = True
    def get_request(self):
        socket, address = super().get_request()
        socket.settimeout(10)
        try:
            return context.wrap_socket(socket, server_side=True), address
        except (OSError, ssl.SSLError):
            socket.close()
            with lock:
                state['tls_failures'] += 1
                publish()
            raise

context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(str(root / 'cert.pem'), str(root / 'key.pem'))
server = Server(('127.0.0.1', 0), Handler)
publish()
(root / 'ready.json.tmp').write_text(json.dumps({'port': server.server_port,
    'url': 'https://localhost:' + str(server.server_port) + '/repo.git'}), encoding='utf-8')
(root / 'ready.json.tmp').replace(root / 'ready.json')
def stop(signum, frame):
    stopping.set()
    threading.Thread(target=server.shutdown, daemon=True).start()
signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
try:
    server.serve_forever(poll_interval=0.05)
finally:
    stopping.set()
    server.server_close()
    publish()
