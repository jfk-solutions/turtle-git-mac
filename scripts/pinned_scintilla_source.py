"""Read immutable Scintilla sources for native Unicode table generators.

A local upstream checkout is authoritative when present. Without one, a verified
cache avoids network access; a cold cache downloads only the pinned Git blob.
Invalid checkout/cache/download bytes fail closed rather than changing sources.
"""
import csv
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request


class PinnedScintillaSources:
    maximum_source_bytes = 16 * 1024 * 1024

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
            data = subprocess.check_output(
                ['git', '-C', str(self.checkout), 'show', self.pin + ':' + path], timeout=30)
            self._verify(path, data)
        elif cached.exists():
            data = cached.read_bytes()
            self._verify(path, data)
            return data.decode('utf-8-sig').replace('\r\n', '\n')
        else:
            url = 'https://raw.githubusercontent.com/TortoiseGit/TortoiseGit/' + self.pin + '/' + path
            with urllib.request.urlopen(url, timeout=30) as response:
                data = response.read(self.maximum_source_bytes + 1)
            self._verify(path, data)
        # Validate decoding before publishing. Preserve original Git bytes in the
        # cache; newline/BOM normalization belongs only to the returned text.
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
