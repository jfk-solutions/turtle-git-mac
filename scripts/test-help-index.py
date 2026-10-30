#!/usr/bin/env python3
"""Private Help-index tool ownership and atomic publication contracts."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('turtlegit_index_help', ROOT / 'scripts/index-help.py')
INDEX_HELP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INDEX_HELP)


class FlushedOutput(io.StringIO):
    def __init__(self):
        super().__init__()
        self.flushed = ''

    def flush(self):
        self.flushed = self.getvalue()


class HelpIndexContracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='turtlegit-help-index-contract-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / 'Private.app'
        self.book = self.app / 'Contents/Resources/TurtleGitHelp.help'
        self.locale = self.book / 'Contents/Resources/en.lproj'
        self.locale.mkdir(parents=True)
        self.topic = self.locale / 'topic.html'
        self.topic.write_bytes(b'<html><body><a name="topic-example"></a>Private help topic</body></html>')
        (self.locale / 'index.html').write_bytes(b'<html><body><a name="topic-home"></a>Private help home</body></html>')
        (self.locale / 'topics.json').write_text(json.dumps({'topics': [{'id': 'example', 'document': 'topic.md'}]}))
        self.info = self.book / 'Contents/Info.plist'
        self.info.write_bytes(plistlib.dumps({'HPDBookCSIndexPath': 'TurtleGitHelp.cshelpindex'}))
        self.manifest = self.locale.parent / 'manifest.json'
        self.save_manifest()
        self.index = self.locale / 'TurtleGitHelp.cshelpindex'
        self.previous = b'previous complete help index'
        self.index.write_bytes(self.previous)
        self.previous_inode = self.index.stat().st_ino
        self.output, self.errors = FlushedOutput(), io.StringIO()
        self.inspection_calls = []

    def save_manifest(self):
        paths = [self.info, self.topic, self.locale / 'index.html', self.locale / 'topics.json']
        self.manifest.write_text(json.dumps({'files': {
            str(path.relative_to(self.book)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths
        }}))

    def index_help(self, **kwargs):
        with contextlib.redirect_stdout(self.output), contextlib.redirect_stderr(self.errors):
            return INDEX_HELP.index_help(self.app, **kwargs)

    def prepared_path(self, argv, kwargs):
        self.assertEqual(argv[:8], ['/usr/bin/hiutil', '-I', 'corespotlight', '-C', '-a', '-s', 'en', '-f'])
        self.assertEqual(argv[9], str(self.locale))
        self.assertEqual(len(argv), 10)
        self.assertTrue(kwargs['check'])
        prepared = Path(argv[8])
        self.assertEqual(prepared.name, self.index.name)
        self.assertNotIn(self.locale, prepared.parents)
        self.assertEqual(prepared.parent.parent, self.locale.parent)
        self.assertEqual(prepared.parent.stat().st_dev, self.locale.stat().st_dev)
        self.assertFalse(prepared.exists())
        self.assertIn('Indexing bundled Mac help', self.output.flushed)
        return prepared

    def modern_runner(self, create, *, missing_anchor=False, wrong_files=False, topic_anchor='topic-example', canonical_anchor=None):
        def run(argv, **kwargs):
            if '-C' in argv:
                return create(argv, **kwargs)
            self.assertEqual(argv[:3], ['/usr/bin/hiutil', '-I', 'corespotlight'])
            self.assertIn(argv[3], ['-D', '-F'])
            self.assertEqual(argv[4], '-f')
            self.assertEqual(len(argv), 6)
            self.assertEqual(Path(argv[5]).name, self.index.name)
            self.assertTrue(kwargs['check'])
            self.assertTrue(kwargs['capture_output'])
            self.assertGreater(kwargs['timeout'], 0)
            self.assertLessEqual(kwargs['timeout'], 300)
            self.inspection_calls.append(argv)
            if argv[3] == '-D':
                anchors = {'topic-home': ['/index.html#topic-home']}
                if not missing_anchor:
                    anchors[topic_anchor] = ['/topic.html#' + (canonical_anchor or topic_anchor)]
                    if canonical_anchor:
                        anchors[canonical_anchor] = ['/topic.html#' + canonical_anchor]
                output = plistlib.dumps(anchors)
            else:
                output = b'/wrong.html\n' if wrong_files else ('/index.html#topic-home\n/topic.html#' + (canonical_anchor or topic_anchor) + '\n').encode()
            return subprocess.CompletedProcess(argv, 0, stdout=output, stderr=b'')
        return run

    def assert_preserved_and_clean(self):
        self.assertEqual(self.index.read_bytes(), self.previous)
        self.assertEqual(self.index.stat().st_ino, self.previous_inode)
        self.assertEqual(list(self.locale.parent.glob('.turtlegit-help-index-*')), [])

    def test_missing_or_changed_manifest_resource_refuses_before_tool(self):
        for missing in (False, True):
            with self.subTest(missing=missing):
                self.topic.unlink(missing_ok=True)
                if not missing:
                    self.topic.write_bytes(b'changed after manifest generation')
                runner = mock.Mock()
                with self.assertRaisesRegex(SystemExit, 'Missing/stale help resource'):
                    self.index_help(runner=runner)
                runner.assert_not_called()
                self.assert_preserved_and_clean()

    def test_nonzero_tool_preserves_old_index_and_cleans_partial(self):
        calls = []
        legacy = self.locale / 'TurtleGitHelp.helpindex'
        legacy.write_bytes(b'previous legacy index')

        def failed(argv, **kwargs):
            prepared = self.prepared_path(argv, kwargs)
            calls.append(argv)
            prepared.write_bytes(b'partial index from failed tool')
            raise subprocess.CalledProcessError(17, argv)

        with self.assertRaises(subprocess.CalledProcessError) as raised:
            self.index_help(runner=failed)
        self.assertEqual(raised.exception.returncode, 17)
        self.assertEqual(len(calls), 1)
        self.assert_preserved_and_clean()
        self.assertEqual(legacy.read_bytes(), b'previous legacy index')
        self.assertIn('indexing failed after', self.errors.getvalue())

    def test_timeout_kills_and_reaps_only_exact_fake_child(self):
        child = self.root / 'fake-indexer.py'
        pid_file = self.root / 'child.pid'
        private_home, private_temporary = self.root / 'home', self.root / 'temporary'
        private_home.mkdir(); private_temporary.mkdir()
        child.write_text('''import os,sys,time
from pathlib import Path
Path(sys.argv[1]).write_text(str(os.getpid()))
Path(sys.argv[2]).write_bytes(b"partial from timed out child")
time.sleep(60)
''')
        calls = []

        def sleeping(argv, **kwargs):
            prepared = self.prepared_path(argv, kwargs)
            calls.append(argv)
            return subprocess.run([sys.executable, str(child), str(pid_file), str(prepared)], cwd=self.root,
                                  env=dict(os.environ, HOME=str(private_home), TMPDIR=str(private_temporary) + '/'), **kwargs)

        with self.assertRaises(subprocess.TimeoutExpired) as raised:
            self.index_help(runner=sleeping, timeout=1.5)
        self.assertGreater(raised.exception.timeout, 0)
        self.assertLessEqual(raised.exception.timeout, 1.5)
        self.assertEqual(len(calls), 1)
        self.assertTrue(pid_file.is_file(), 'Fake child did not reach its owned partial-output phase')
        pid = int(pid_file.read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)
        with self.assertRaises(ChildProcessError):
            os.waitpid(pid, os.WNOHANG)
        self.assert_preserved_and_clean()
        self.assertIn('indexing failed after', self.errors.getvalue())

    def test_success_atomically_publishes_fresh_index_after_tool_completion(self):
        prepared_paths = []
        new_index = b'new complete index'

        def succeed(argv, **kwargs):
            self.assertGreater(kwargs['timeout'], 0)
            self.assertLessEqual(kwargs['timeout'], 300)
            prepared = self.prepared_path(argv, kwargs)
            prepared_paths.append(prepared)
            self.assertEqual(self.index.read_bytes(), self.previous)
            prepared.write_bytes(new_index)
            self.assertEqual(self.index.read_bytes(), self.previous)
            return subprocess.CompletedProcess(argv, 0)

        with mock.patch.object(INDEX_HELP.os, 'replace', wraps=os.replace) as publish:
            result = self.index_help(runner=self.modern_runner(succeed))
        self.assertEqual(result, self.index)
        self.assertEqual(self.index.read_bytes(), new_index)
        self.assertNotEqual(self.index.stat().st_ino, self.previous_inode)
        publish.assert_called_once_with(prepared_paths[0], self.index)
        self.assertFalse(prepared_paths[0].exists())
        self.assertEqual(list(self.locale.parent.glob('.turtlegit-help-index-*')), [])
        self.assertIn('bytes in', self.output.getvalue())
        self.assertEqual([argv[3] for argv in self.inspection_calls], ['-D', '-F'])

    def test_success_without_previous_index_creates_final_only_at_publication(self):
        self.index.unlink()

        def succeed(argv, **kwargs):
            prepared = self.prepared_path(argv, kwargs)
            self.assertFalse(self.index.exists())
            prepared.write_bytes(b'first complete index')
            return subprocess.CompletedProcess(argv, 0)

        self.index_help(runner=self.modern_runner(succeed))
        self.assertEqual(self.index.read_bytes(), b'first complete index')
        self.assertEqual(list(self.locale.parent.glob('.turtlegit-help-index-*')), [])

    def test_zero_exit_with_missing_or_empty_output_still_fails(self):
        for empty in (False, True):
            with self.subTest(empty=empty):
                def incomplete(argv, **kwargs):
                    prepared = self.prepared_path(argv, kwargs)
                    if empty:
                        prepared.write_bytes(b'')
                    return subprocess.CompletedProcess(argv, 0)

                with self.assertRaisesRegex(RuntimeError, 'index was not generated'):
                    self.index_help(runner=incomplete)
                self.assert_preserved_and_clean()

    def test_failed_atomic_replace_preserves_previous_index(self):
        def succeed(argv, **kwargs):
            self.prepared_path(argv, kwargs).write_bytes(b'complete but unpublished index')
            return subprocess.CompletedProcess(argv, 0)

        with mock.patch.object(INDEX_HELP.os, 'replace', side_effect=OSError('publication refused')):
            with self.assertRaisesRegex(OSError, 'publication refused'):
                self.index_help(runner=self.modern_runner(succeed))
        self.assert_preserved_and_clean()

    def test_legacy_metadata_refuses_before_tool_even_when_hashes_match(self):
        self.info.write_bytes(plistlib.dumps({'HPDBookIndexPath': 'TurtleGitHelp.helpindex'}))
        self.save_manifest()
        runner = mock.Mock()
        with self.assertRaisesRegex(SystemExit, 'HPDBookCSIndexPath'):
            self.index_help(runner=runner)
        runner.assert_not_called()
        self.assert_preserved_and_clean()

    def test_unreadable_or_incomplete_modern_inventory_is_not_published(self):
        legacy = self.locale / 'TurtleGitHelp.helpindex'
        legacy.write_bytes(b'legacy index retained until modern inspection succeeds')
        for missing_anchor, wrong_files in [(True, False), (False, True)]:
            with self.subTest(missing_anchor=missing_anchor, wrong_files=wrong_files):
                def succeed(argv, **kwargs):
                    self.prepared_path(argv, kwargs).write_bytes(b'nonempty but incomplete modern index')
                    return subprocess.CompletedProcess(argv, 0)

                with self.assertRaisesRegex(RuntimeError, 'missing the document target|HTML inventory differs'):
                    self.index_help(runner=self.modern_runner(succeed, missing_anchor=missing_anchor, wrong_files=wrong_files))
                self.assert_preserved_and_clean()
                self.assertEqual(legacy.read_bytes(), b'legacy index retained until modern inspection succeeds')

    def test_successful_migration_removes_only_legacy_before_modern_publication(self):
        legacy = self.locale / 'TurtleGitHelp.helpindex'
        legacy.write_bytes(b'old legacy data')
        replace = os.replace

        def succeed(argv, **kwargs):
            self.prepared_path(argv, kwargs).write_bytes(b'validated modern index')
            self.assertTrue(legacy.exists())
            return subprocess.CompletedProcess(argv, 0)

        def publish(source, destination):
            self.assertFalse(legacy.exists())
            self.assertEqual(self.index.read_bytes(), self.previous)
            return replace(source, destination)

        with mock.patch.object(INDEX_HELP.os, 'replace', side_effect=publish):
            self.index_help(runner=self.modern_runner(succeed))
        self.assertFalse(legacy.exists())
        self.assertEqual(self.index.read_bytes(), b'validated modern index')
        self.assertEqual(list(self.locale.parent.glob('.turtlegit-help-index-*')), [])

    def test_legacy_cleanup_failure_keeps_previous_active_modern_index(self):
        legacy = self.locale / 'TurtleGitHelp.helpindex'
        legacy.write_bytes(b'old legacy data')

        def succeed(argv, **kwargs):
            self.prepared_path(argv, kwargs).write_bytes(b'complete but unpublished modern index')
            return subprocess.CompletedProcess(argv, 0)

        with mock.patch.object(Path, 'unlink', side_effect=OSError('legacy cleanup refused')):
            with self.assertRaisesRegex(OSError, 'legacy cleanup refused'):
                self.index_help(runner=self.modern_runner(succeed))
        self.assert_preserved_and_clean()
        self.assertEqual(legacy.read_bytes(), b'old legacy data')

    def test_current_bundle_verification_inspects_without_generation_and_rejects_legacy_extra(self):
        def no_generation(*args, **kwargs):
            self.fail('Verification attempted to generate an index')

        runner = self.modern_runner(no_generation)
        with contextlib.redirect_stdout(self.output):
            INDEX_HELP.verify_help_index(self.app, runner=runner)
        self.assertEqual([argv[3] for argv in self.inspection_calls], ['-D', '-F'])
        self.assert_preserved_and_clean()
        legacy = self.locale / 'TurtleGitHelp.helpindex'
        legacy.write_bytes(b'obsolete extra member')
        refused = mock.Mock()
        with self.assertRaisesRegex(SystemExit, 'Unexpected bundled Help files'):
            INDEX_HELP.verify_help_index(self.app, runner=refused)
        refused.assert_not_called()
        self.assertEqual(legacy.read_bytes(), b'obsolete extra member')

    def test_shared_chapter_canonical_anchor_preserves_exact_alias_identity(self):
        self.topic.write_bytes(b'<a name="topic-clone"></a><a name="topic-createRepository"></a>Private chapter')
        (self.locale / 'topics.json').write_text(json.dumps({'topics': [{'id': 'createRepository', 'document': 'topic.md'}]}))
        self.save_manifest()

        def succeed(argv, **kwargs):
            self.prepared_path(argv, kwargs).write_bytes(b'modern index with shared canonical chapter URL')
            return subprocess.CompletedProcess(argv, 0)

        self.index_help(runner=self.modern_runner(succeed, topic_anchor='topic-createRepository', canonical_anchor='topic-clone'))
        self.assertEqual(self.index.read_bytes(), b'modern index with shared canonical chapter URL')
        self.assertEqual(list(self.locale.parent.glob('.turtlegit-help-index-*')), [])

    def test_alias_rejects_wrong_chapter_unknown_fragment_and_changed_key_case(self):
        for mismatch in ['chapter', 'fragment', 'case']:
            with self.subTest(mismatch=mismatch):
                def succeed(argv, **kwargs):
                    self.prepared_path(argv, kwargs).write_bytes(b'index with invalid alias target')
                    return subprocess.CompletedProcess(argv, 0)

                base = self.modern_runner(succeed)

                def incorrect(argv, **kwargs):
                    result = base(argv, **kwargs)
                    if '-D' in argv:
                        anchors = plistlib.loads(result.stdout)
                        if mismatch == 'chapter':
                            anchors['topic-example'] = ['/index.html#topic-home']
                        elif mismatch == 'fragment':
                            anchors['topic-example'] = ['/topic.html#unknown']
                        else:
                            anchors['TOPIC-EXAMPLE'] = anchors.pop('topic-example')
                        result.stdout = plistlib.dumps(anchors)
                    return result

                with self.assertRaisesRegex(RuntimeError, 'wrong document target|unknown canonical anchor|missing the document target'):
                    self.index_help(runner=incorrect)
                self.assert_preserved_and_clean()

    def test_declared_anchor_must_exist_in_hash_validated_chapter(self):
        self.topic.write_bytes(b'<a name="another-anchor"></a>Chapter missing its declared topic anchor')
        self.save_manifest()

        def succeed(argv, **kwargs):
            self.prepared_path(argv, kwargs).write_bytes(b'index claiming a missing HTML anchor')
            return subprocess.CompletedProcess(argv, 0)

        with self.assertRaisesRegex(RuntimeError, 'missing the named anchor'):
            self.index_help(runner=self.modern_runner(succeed))
        self.assert_preserved_and_clean()


if __name__ == '__main__':
    unittest.main()
