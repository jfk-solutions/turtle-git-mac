#!/usr/bin/env python3
import hashlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
from pinned_download import download_verified


class Response(io.BytesIO):
    def __init__(self, data, length=None):
        super().__init__(data)
        self.headers = {'Content-Length': str(len(data) if length is None else length)}


class PinnedDownloadTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.file = Path(self.directory.name) / 'archive.tar.gz'
        self.payload = b'pinned fixture bytes'
        self.digest = hashlib.sha256(self.payload).hexdigest()
    def test_dns_and_truncated_response_retry_then_publish_verified_bytes(self):
        with patch('pinned_download.urllib.request.urlopen', side_effect=[urllib.error.URLError('DNS fixture'), Response(b'partial', 100), Response(self.payload)]) as request, patch('pinned_download.time.sleep'):
            download_verified('https://fixture.invalid/source', self.file, self.digest)
            self.assertEqual(request.call_count, 3)
        self.assertEqual(self.file.read_bytes(), self.payload)
        self.assertEqual(list(self.file.parent.glob('*.download')), [])
    def test_checksum_mismatch_never_retries_or_publishes(self):
        with patch('pinned_download.urllib.request.urlopen', return_value=Response(b'wrong')) as request:
            with self.assertRaisesRegex(RuntimeError, 'checksum mismatch'):
                download_verified('https://fixture.invalid/source', self.file, self.digest)
            self.assertEqual(request.call_count, 1)
        self.assertFalse(self.file.exists()); self.assertEqual(list(self.file.parent.glob('*.download')), [])
    def test_permanent_http_error_and_retry_exhaustion_leave_no_archive(self):
        for error, count in [(urllib.error.HTTPError('url', 404, 'missing', {}, None), 1), (urllib.error.URLError('DNS fixture'), 3)]:
            with patch('pinned_download.urllib.request.urlopen', side_effect=error) as request, patch('pinned_download.time.sleep'):
                with self.assertRaises(urllib.error.URLError):
                    download_verified('https://fixture.invalid/source', self.file, self.digest)
                self.assertEqual(request.call_count, count)
            self.assertFalse(self.file.exists()); self.assertEqual(list(self.file.parent.glob('*.download')), [])
    def test_cached_sources_verified_without_network_or_replacement(self):
        self.file.write_bytes(self.payload)
        with patch('pinned_download.urllib.request.urlopen') as request:
            download_verified('https://fixture.invalid/source', self.file, self.digest)
            self.assertEqual(request.call_count, 0)
            self.file.write_bytes(b'corrupt cache')
            with self.assertRaisesRegex(RuntimeError, 'Cached source'):
                download_verified('https://fixture.invalid/source', self.file, self.digest)
        self.assertEqual(self.file.read_bytes(), b'corrupt cache')


if __name__ == '__main__':
    unittest.main()
