#!/usr/bin/env python3
"""Offline availability and integrity contracts for both Unicode generators."""
import csv
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from pinned_scintilla_source import PinnedScintillaSources


class PinnedScintillaSourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='turtlegit-pinned-unicode-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.pin = '7' * 40
        self.name = 'CaseConvert.cxx'
        self.data = b'\xef\xbb\xbf// pinned Unicode source\r\n'
        self.path = 'ext/scintilla/src/' + self.name
        (self.root / 'docs').mkdir()
        (self.root / 'docs/upstream.json').write_text(json.dumps({'commit': self.pin}))
        blob = hashlib.sha1(b'blob ' + str(len(self.data)).encode() + b'\0' + self.data).hexdigest()
        with (self.root / 'docs/upstream-files.csv').open('w', newline='') as stream:
            writer = csv.DictWriter(stream, fieldnames=['path', 'blob'])
            writer.writeheader()
            writer.writerow({'path': self.path, 'blob': blob})
        self.sources = PinnedScintillaSources(self.root)
        self.cached = self.sources.cache / self.name

    def cache(self, data):
        self.sources.cache.mkdir(parents=True)
        self.cached.write_bytes(data)

    def checkout(self):
        self.sources.checkout.mkdir(parents=True)
        # Git worktrees use a .git file rather than a directory.
        (self.sources.checkout / '.git').write_text('gitdir: unused-test-placeholder')

    def test_cold_no_checkout_downloads_exact_pinned_blob_then_preserves_git_bytes(self):
        with patch('pinned_scintilla_source.urllib.request.urlopen', return_value=io.BytesIO(self.data)) as network, \
             patch('pinned_scintilla_source.subprocess.check_output') as git:
            self.assertEqual(self.sources.source(self.name), '// pinned Unicode source\n')
        network.assert_called_once_with(
            'https://raw.githubusercontent.com/TortoiseGit/TortoiseGit/' + self.pin + '/' + self.path,
            timeout=30)
        git.assert_not_called()
        self.assertEqual(self.cached.read_bytes(), self.data)
        self.assertEqual(list(self.sources.cache.glob('*.tmp')), [])

    def test_valid_warm_cache_needs_neither_checkout_nor_network(self):
        self.cache(self.data)
        with patch('pinned_scintilla_source.urllib.request.urlopen') as network, \
             patch('pinned_scintilla_source.subprocess.check_output') as git:
            self.assertEqual(self.sources.source(self.name), '// pinned Unicode source\n')
        network.assert_not_called()
        git.assert_not_called()
        self.assertEqual(self.cached.read_bytes(), self.data)

    def test_bad_cached_blob_fails_without_network_or_repair(self):
        self.cache(b'changed cached Unicode source')
        with patch('pinned_scintilla_source.urllib.request.urlopen') as network:
            with self.assertRaisesRegex(ValueError, 'Git blob differs'):
                self.sources.source(self.name)
        network.assert_not_called()
        self.assertEqual(self.cached.read_bytes(), b'changed cached Unicode source')

    def test_bad_download_is_never_published(self):
        with patch('pinned_scintilla_source.urllib.request.urlopen', return_value=io.BytesIO(b'wrong source')):
            with self.assertRaisesRegex(ValueError, 'Git blob differs'):
                self.sources.source(self.name)
        self.assertFalse(self.cached.exists())
        self.assertFalse(self.sources.cache.exists())

    def test_available_checkout_is_pinned_and_verified_before_cache_publication(self):
        self.checkout()
        with patch('pinned_scintilla_source.subprocess.check_output', return_value=self.data) as git, \
             patch('pinned_scintilla_source.urllib.request.urlopen') as network:
            self.assertEqual(self.sources.source(self.name), '// pinned Unicode source\n')
        git.assert_called_once_with(
            ['git', '-C', str(self.sources.checkout), 'show', self.pin + ':' + self.path], timeout=30)
        network.assert_not_called()
        self.assertEqual(self.cached.read_bytes(), self.data)

    def test_bad_checkout_blob_does_not_fall_back_to_good_cache(self):
        self.checkout()
        self.cache(self.data)
        with patch('pinned_scintilla_source.subprocess.check_output', return_value=b'wrong checkout source'), \
             patch('pinned_scintilla_source.urllib.request.urlopen') as network:
            with self.assertRaisesRegex(ValueError, 'Git blob differs'):
                self.sources.source(self.name)
        network.assert_not_called()
        self.assertEqual(self.cached.read_bytes(), self.data)

    def test_traversal_and_unpinned_file_names_are_rejected_before_io(self):
        with patch('pinned_scintilla_source.urllib.request.urlopen') as network, \
             patch('pinned_scintilla_source.subprocess.check_output') as git:
            for name in ('../CaseConvert.cxx', '/CaseConvert.cxx', 'Missing.cxx'):
                with self.subTest(name=name), self.assertRaises(ValueError):
                    self.sources.source(name)
        network.assert_not_called()
        git.assert_not_called()

    def test_pinned_commit_is_not_a_mutable_branch(self):
        (self.root / 'docs/upstream.json').write_text(json.dumps({'commit': 'main'}))
        with self.assertRaisesRegex(ValueError, 'pinned upstream commit'):
            PinnedScintillaSources(self.root)

    def test_oversized_download_is_bounded_and_not_cached(self):
        self.sources.maximum_source_bytes = 8
        with patch('pinned_scintilla_source.urllib.request.urlopen', return_value=io.BytesIO(self.data)):
            with self.assertRaisesRegex(ValueError, 'size limit'):
                self.sources.source(self.name)
        self.assertFalse(self.cached.exists())


if __name__ == '__main__':
    unittest.main()
