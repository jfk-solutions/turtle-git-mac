"""Bounded, checksum-verified downloads for runtime reconstruction scripts."""
import hashlib
import http.client
import os
from pathlib import Path
import tempfile
import time
import urllib.error
import urllib.request


def digest_file(path, algorithm):
    value = hashlib.new(algorithm)
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def download_verified(url, destination, expected, algorithm='sha256', attempts=3):
    destination = Path(destination)
    if not 1 <= attempts <= 5:
        raise ValueError('Use one through five download attempts.')
    if destination.exists():
        if digest_file(destination, algorithm) != expected:
            raise RuntimeError('Cached source checksum mismatch: ' + destination.name)
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(attempts):
        part = None
        try:
            with tempfile.NamedTemporaryFile(prefix=destination.name + '.', suffix='.download', dir=destination.parent, delete=False) as stream:
                part = Path(stream.name)
                with urllib.request.urlopen(url, timeout=30) as response:
                    length = response.headers.get('Content-Length')
                    received = 0
                    while True:
                        block = response.read(1024 * 1024)
                        if not block:
                            break
                        stream.write(block); received += len(block)
                    if length is not None and received != int(length):
                        raise http.client.IncompleteRead(b'', int(length) - received)
                stream.flush(); os.fsync(stream.fileno())
            if digest_file(part, algorithm) != expected:
                raise RuntimeError('Downloaded source checksum mismatch: ' + destination.name)
            os.replace(part, destination)
            return destination
        except (urllib.error.URLError, TimeoutError, ConnectionError, http.client.IncompleteRead) as error:
            if isinstance(error, urllib.error.HTTPError) and error.code not in {408, 429, 500, 502, 503, 504}:
                raise
            if attempt + 1 == attempts:
                raise
            print('Retrying pinned download ' + destination.name + ' (' + str(attempt + 2) + '/' + str(attempts) + ')', flush=True)
            time.sleep(attempt + 1)
        finally:
            if part is not None:
                part.unlink(missing_ok=True)
