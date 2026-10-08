#!/usr/bin/env python3
"""Exercise the real bundled LFS client against an owned loopback locking server."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from urllib.parse import parse_qs, urlsplit

def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('runtime', type=Path); args = parser.parse_args()
    runtime = args.runtime.resolve(); locks = {}; requests = []; counter = [100]
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def respond(self, status, value):
            data = json.dumps(value).encode(); self.send_response(status); self.send_header('Content-Type', 'application/vnd.git-lfs+json'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
        def do_GET(self):
            assert not self.headers.get('Authorization'), 'Fixture must not receive credentials'
            parsed = urlsplit(self.path); query = parse_qs(parsed.query); requests.append(('GET', parsed.path))
            if parsed.path != '/locks': self.respond(404, {'message': 'unknown fixture route'}); return
            values = list(locks.values())
            if 'path' in query: values = [lock for lock in values if lock['path'] == query['path'][0]]
            if 'id' in query: values = [lock for lock in values if lock['id'] == query['id'][0]]
            self.respond(200, {'locks': values, 'next_cursor': ''})
        def do_POST(self):
            assert not self.headers.get('Authorization'), 'Fixture must not receive credentials'
            data = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
            path = urlsplit(self.path).path; requests.append(('POST', path, data))
            if path == '/locks':
                if any(lock['path'] == data['path'] for lock in locks.values()): self.respond(409, {'message': 'already locked'}); return
                counter[0] += 1; identity = str(counter[0]); lock = dict(id=identity, path=data['path'], locked_at='2026-10-08T20:00:00Z', owner={'name': 'QA'})
                locks[identity] = lock; self.respond(201, {'lock': lock}); return
            parts = path.strip('/').split('/')
            if len(parts) == 3 and parts[0] == 'locks' and parts[2] == 'unlock' and parts[1] in locks:
                lock = locks[parts[1]]
                if lock['owner']['name'] != 'QA' and not data.get('force'):
                    self.respond(403, {'message': 'owned by another user'}); return
                del locks[parts[1]]; self.respond(200, {'lock': lock}); return
            self.respond(404, {'message': 'unknown fixture route'})
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler); server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='turtlegit-lfs-protocol-') as temporary:
            root = Path(temporary); repository = root / 'repository'; repository.mkdir()
            # Drop the child home entry so Git LFS's netrc loader has no user file.
            # Explicit Git config paths and local repository config isolate this fixture.
            environment = {k: v for k, v in os.environ.items() if not k.startswith('GIT_') and k not in ['HOME', 'XDG_CONFIG_HOME', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy']}
            environment.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_TERMINAL_PROMPT='0', GIT_PAGER='cat', LC_ALL='C', NO_PROXY='127.0.0.1,localhost', GIT_EXEC_PATH=str(runtime / 'libexec/git-core'), GIT_TEMPLATE_DIR=str(runtime / 'share/git-core/templates'), PATH=str(runtime / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin')
            def run(*arguments, success=True):
                result = subprocess.run([runtime / 'bin/git', '--literal-pathspecs', '-C', repository, *arguments], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
                assert (result.returncode == 0) == success, (arguments, result.stdout, result.stderr)
                return result.stdout
            run('init', '-b', 'main'); run('config', 'user.name', 'QA'); run('config', 'user.email', 'qa@example.invalid'); run('config', 'commit.gpgsign', 'false')
            run('config', 'credential.helper', ''); run('config', 'lfs.url', 'http://127.0.0.1:' + str(server.server_port)); run('config', 'remote.origin.url', 'http://127.0.0.1:' + str(server.server_port) + '/repository.git')
            run('lfs', 'install', '--local'); run('lfs', 'track', '--lockable', '*.bin')
            paths = ['-雪\t\n🦎.bin', 'other.bin', 'last.bin']; originals = {path: bytes(range(128)) + path.encode() for path in paths}
            for path, data in originals.items(): (repository / path).write_bytes(data)
            run('add', '--', '.gitattributes', *paths); run('commit', '-m', 'LFS base')
            for path, data in originals.items():
                pointer = run('show', ':' + path)
                assert b'version https://git-lfs.github.com/spec/v1\n' in pointer and ('oid sha256:' + hashlib.sha256(data).hexdigest()).encode() in pointer
            head = run('rev-parse', 'HEAD'); staged = run('ls-files', '--stage', '-z')
            run('lfs', 'lock', '--', paths[0]); run('lfs', 'lock', '--', paths[2])
            locks['other'] = dict(id='other', path=paths[1], locked_at='2026-10-08T20:00:00Z', owner={'name': 'Other'})
            listed = json.loads(run('lfs', 'locks', '--json')); assert {lock['path'] for lock in listed} == set(paths)
            run('lfs', 'unlock', '--', paths[0]); run('lfs', 'unlock', '--', paths[1], success=False); run('lfs', 'unlock', '--', paths[2])
            assert list(locks) == ['other']; run('lfs', 'unlock', '--force', '--', paths[1]); assert json.loads(run('lfs', 'locks', '--json')) == []
            assert any(request[0] == 'POST' and request[1] == '/locks/other/unlock' and request[2].get('force') for request in requests)
            assert run('rev-parse', 'HEAD') == head and run('ls-files', '--stage', '-z') == staged
            assert all((repository / path).read_bytes() == data for path, data in originals.items())
            print('PASS: real bundled Git LFS install/track/clean pointer conversion, Unicode/tab/newline/option-like literal paths, loopback JSON lock listing, per-file unlock continuation after ownership failure and explicit force; HEAD/staged entries/worktree bytes preserved. No public server, credentials or signed sandbox acceptance.')
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=5); assert not thread.is_alive()

if __name__ == '__main__': main()
