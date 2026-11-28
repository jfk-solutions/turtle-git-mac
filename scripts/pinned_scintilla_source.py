"""Read immutable Scintilla sources for native Unicode table generators.

A local upstream checkout is authoritative when present. Without one, a verified
cache avoids network access; a cold cache downloads only the pinned Git blob.
Invalid checkout/cache/download bytes fail closed rather than changing sources.
"""
import csv
import hashlib
import errno
import http.client
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time
import socket
import urllib.error
import urllib.request


class PinnedScintillaSources:
    maximum_source_bytes = 16 * 1024 * 1024
    download_attempts = 3

    @staticmethod
    def _transient_transport(error):
        # Match the bounded runtime downloader's retry/status policy, while
        # leaving certificate, invalid-URL and permanent DNS errors terminal.
        if isinstance(error, urllib.error.HTTPError):
            return error.code in {408, 429, 500, 502, 503, 504}
        if isinstance(error, urllib.error.URLError):
            return PinnedScintillaSources._transient_transport(error.reason)
        if isinstance(error, socket.gaierror):
            return error.errno == socket.EAI_AGAIN
        if isinstance(error, (TimeoutError, ConnectionError,
                              http.client.IncompleteRead, http.client.RemoteDisconnected)):
            return True
        return isinstance(error, OSError) and error.errno in {
            errno.ETIMEDOUT, errno.ECONNRESET, errno.ECONNABORTED,
            errno.ECONNREFUSED, errno.ENETDOWN, errno.ENETUNREACH, errno.EHOSTUNREACH,
        }

    def _download(self, path):
        url = 'https://raw.githubusercontent.com/TortoiseGit/TortoiseGit/' + self.pin + '/' + path
        for attempt in range(self.download_attempts):
            print('Pinned Scintilla download ' + path + ' (' + str(attempt + 1) + '/' + str(self.download_attempts) + ')', flush=True)
            try:
                with urllib.request.urlopen(url, timeout=30) as response:
                    return response.read(self.maximum_source_bytes + 1)
            except (urllib.error.URLError, OSError, http.client.IncompleteRead,
                    http.client.RemoteDisconnected) as error:
                if not self._transient_transport(error) or attempt + 1 == self.download_attempts:
                    print('Pinned Scintilla download failed: ' + path + ' (' + type(error).__name__ + ')', flush=True)
                    raise
                print('Retrying pinned Scintilla transport: ' + path + ' (' + type(error).__name__ + ')', flush=True)
                time.sleep(attempt + 1)
        raise AssertionError('Pinned Scintilla download attempt bound exhausted')

    def __init__(self, root):
        self.root = Path(root)
        self.pin = json.loads((self.root / 'docs/upstream.json').read_text())['commit']
        if not re.fullmatch(r'[0-9a-f]{40}', self.pin):
            raise ValueError('Invalid pinned upstream commit')
        with (self.root / 'docs/upstream-files.csv').open(newline='') as stream:
            rows = list(csv.DictReader(stream))
        self.blobs = {}
        for row in rows:
            path, blob = row['path'], row['blob']
            if path.startswith('ext/scintilla/src/'):
                if path in self.blobs or not re.fullmatch(r'[0-9a-f]{40}', blob):
                    raise ValueError('Invalid or duplicate pinned Scintilla blob: ' + path)
                self.blobs[path] = blob
        self.checkout = self.root / '.upstream/TortoiseGit'
        self.cache = self.root / 'build/qa/unified-find-source' / self.pin

    def _verify(self, path, data):
        if len(data) > self.maximum_source_bytes:
            raise ValueError('Pinned Scintilla source exceeds size limit: ' + path)
        actual = hashlib.sha1(b'blob ' + str(len(data)).encode('ascii') + b'\0' + data).hexdigest()
        if actual != self.blobs[path]:
            raise ValueError('Pinned Scintilla Git blob differs: ' + path)

    def source(self, name):
        if not re.fullmatch(r'[A-Za-z0-9_]+\.(?:cxx|h)', name):
            raise ValueError('Invalid Scintilla source name')
        path = 'ext/scintilla/src/' + name
        if path not in self.blobs:
            raise ValueError('Scintilla source missing from pinned inventory: ' + path)
        cached = self.cache / name
        if (self.checkout / '.git').exists():
            print('Pinned Scintilla checkout: ' + path, flush=True)
            data = subprocess.check_output(
                ['git', '-C', str(self.checkout), 'show', self.pin + ':' + path], timeout=30)
            self._verify(path, data)
        elif cached.exists():
            print('Pinned Scintilla cache: ' + path, flush=True)
            data = cached.read_bytes()
            self._verify(path, data)
            return data.decode('utf-8-sig').replace('\r\n', '\n')
        else:
            data = self._download(path)
            self._verify(path, data)
        # Validate decoding before publishing. Preserve original Git bytes in the
        # cache; newline/BOM normalization belongs only to the returned text.
        print('Pinned Scintilla verified blob/decode: ' + path, flush=True)
        text = data.decode('utf-8-sig').replace('\r\n', '\n')
        self.cache.mkdir(parents=True, exist_ok=True)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(prefix=name + '.', suffix='.tmp', dir=self.cache, delete=False) as stream:
                temporary = Path(stream.name)
                stream.write(data)
            temporary.replace(cached)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
        return text
