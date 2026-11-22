#!/usr/bin/env python3
"""Exercise source reconstruction entry without a native toolchain or build."""
import contextlib
import hashlib
import http.server
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('svn_builder', ROOT / 'scripts/build-git-svn-runtime.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class SourceFetchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='TurtleGitSourceFetch-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.requests = []
        self.responses = {}
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                owner.requests.append(self.path)
                status, body = owner.responses.get(self.path, (404, b'missing'))
                self.send_response(status)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_):
                pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        url = 'http://127.0.0.1:' + str(self.server.server_port)

        def pin(name, algorithm='sha256'):
            body = ('independent ' + name + ' fixture bytes').encode()
            path = '/' + name + '.tar.gz'
            self.responses[path] = (200, body)
            return dict(version='1.0', url=url + path, hash=algorithm,
                        digest=hashlib.new(algorithm, body).hexdigest())

        self.pin = dict(sources={'perl': pin('perl'), 'apr-util': pin('apr-util', 'sha512')},
                        git_pin='Configuration/GitRuntime.json', architectures=['arm64'],
                        build_tools={'scons': pin('scons')})
        git = pin('git')
        config = self.root / 'Configuration'
        config.mkdir()
        (config / 'GitSVNRuntime.json').write_text(json.dumps(self.pin))
        (config / 'GitRuntime.json').write_text(json.dumps(dict(version=git['version'], source_url=git['url'], source_sha256=git['digest'])))
        self.output = self.root / 'existing-runtime'
        self.output.mkdir()
        self.sentinel = self.output / 'keep.bin'
        self.sentinel.write_bytes(b'existing runtime must not be replaced')

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.assertFalse(self.thread.is_alive(), 'Owned source server did not drain')

    def invoke(self, fetch_only=True):
        output = io.StringIO()
        args = ['build-git-svn-runtime.py', '--output', str(self.output)]
        if fetch_only:
            args.append('--fetch-only')
        with patch.object(builder, 'ROOT', self.root), patch('sys.argv', args), contextlib.redirect_stdout(output), \
             patch.object(builder, 'extract', side_effect=AssertionError('fetch extracted sources')), \
             patch.object(builder, 'run', side_effect=AssertionError('fetch invoked build')), \
             patch.object(builder.subprocess, 'check_output', side_effect=AssertionError('fetch probed toolchain')), \
             patch.object(builder.zipfile, 'ZipFile', side_effect=AssertionError('fetch extracted build tool')):
            builder.main()
        return output.getvalue()

    def test_all_input_kinds_verify_before_toolchain_and_leave_existing_output(self):
        cold = self.invoke()
        receipt = json.loads(cold.splitlines()[-1])
        self.assertEqual(receipt['mode'], 'fetch-only')
        self.assertEqual([x['component'] for x in receipt['verified_inputs']], ['perl', 'apr-util', 'git', 'scons'])
        self.assertEqual(self.requests, ['/perl.tar.gz', '/apr-util.tar.gz', '/git.tar.gz', '/scons.tar.gz'])
        for item in receipt['verified_inputs']:
            data = Path(item['path']).read_bytes()
            self.assertEqual(len(data), item['bytes'])
            self.assertEqual(hashlib.new(item['algorithm'], data).hexdigest(), item['digest'])
            self.assertIn(item['url'], cold)
        self.assertEqual(self.sentinel.read_bytes(), b'existing runtime must not be replaced')
        self.assertEqual(list(self.output.iterdir()), [self.sentinel])
        cache = self.root / 'build/git-svn-runtime/cache'
        self.assertEqual(sorted(x.name for x in cache.iterdir()), ['apr-util.tar.gz', 'git.tar.gz', 'perl.tar.gz', 'scons.tar.gz'])
        self.assertEqual(list((self.root / 'build/git-svn-runtime').iterdir()), [cache])
        self.requests.clear()
        warm = self.invoke()
        self.assertEqual(self.requests, [])
        self.assertEqual(json.loads(warm.splitlines()[-1]), receipt)

    def test_permanent_http_failure_names_exact_component_and_retains_cause(self):
        self.responses['/apr-util.tar.gz'] = (404, b'gone')
        with self.assertRaises(RuntimeError) as captured:
            self.invoke()
        message = str(captured.exception)
        self.assertIn('apr-util 1.0', message)
        self.assertIn(self.pin['sources']['apr-util']['url'], message)
        self.assertIn(str(self.root / 'build/git-svn-runtime/cache/apr-util.tar.gz'), message)
        self.assertIsInstance(captured.exception.__cause__, urllib.error.HTTPError)
        self.assertEqual(captured.exception.__cause__.code, 404)
        self.assertEqual(self.requests, ['/perl.tar.gz', '/apr-util.tar.gz'])
        self.assertFalse((self.root / 'build/git-svn-runtime/cache/apr-util.tar.gz').exists())
        self.assertEqual(list(self.root.rglob('*.download')), [])
        self.assertEqual(self.sentinel.read_bytes(), b'existing runtime must not be replaced')

    def test_corrupt_cached_source_fails_with_identity_without_network_or_repair(self):
        self.invoke()
        self.requests.clear()
        cached = self.root / 'build/git-svn-runtime/cache/perl.tar.gz'
        cached.write_bytes(b'corrupt cached input')
        with self.assertRaises(RuntimeError) as captured:
            self.invoke()
        self.assertIn('perl 1.0', str(captured.exception))
        self.assertIn(self.pin['sources']['perl']['url'], str(captured.exception))
        self.assertIn('Cached source checksum mismatch', str(captured.exception))
        self.assertEqual(self.requests, [])
        self.assertEqual(cached.read_bytes(), b'corrupt cached input')

    def test_ordinary_build_still_refuses_existing_output_before_download(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as captured:
            self.invoke(fetch_only=False)
        self.assertEqual(captured.exception.code, 2)
        self.assertEqual(self.requests, [])
        self.assertFalse((self.root / 'build').exists())
        self.assertEqual(self.sentinel.read_bytes(), b'existing runtime must not be replaced')


if __name__ == '__main__':
    unittest.main()
