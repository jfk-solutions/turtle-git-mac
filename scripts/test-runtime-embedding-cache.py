#!/usr/bin/env python3
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('runtime_embedding', Path(__file__).with_name('embed-app-runtimes.py'))
runtime = importlib.util.module_from_spec(spec); spec.loader.exec_module(runtime)

class RuntimeEmbeddingCacheTests(unittest.TestCase):
    def test_only_unsigned_debug_is_eligible(self):
        self.assertTrue(runtime.development_reuse({'CONFIGURATION': 'Debug', 'CODE_SIGNING_ALLOWED': 'NO'}))
        for configuration in ['Debug', 'Release', 'AppStore', '']:
            for signing in ['YES', '', 'NO']:
                if configuration == 'Debug' and signing == 'NO': continue
                self.assertFalse(runtime.development_reuse({'CONFIGURATION': configuration, 'CODE_SIGNING_ALLOWED': signing}))

    def test_content_permissions_links_names_and_optional_presence_invalidate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); directory = root/'kit'; directory.mkdir()
            binary = directory/'helper'; binary.write_bytes(b'original'); binary.chmod(0o755)
            alias = directory/'alias'; alias.symlink_to('helper')
            paths = {'runtime': directory, 'optional': root/'absent'}
            original = runtime.fingerprint(paths)
            # A same-length edit retaining timestamps cannot hide a changed binary.
            previous = binary.stat(); binary.write_bytes(b'modified')
            os.utime(binary, ns=(previous.st_atime_ns, previous.st_mtime_ns))
            self.assertNotEqual(original, runtime.fingerprint(paths)); binary.write_bytes(b'original')
            self.assertEqual(original, runtime.fingerprint(paths))
            binary.chmod(0o644); self.assertNotEqual(original, runtime.fingerprint(paths)); binary.chmod(0o755)
            alias.unlink(); alias.symlink_to('other'); self.assertNotEqual(original, runtime.fingerprint(paths))
            alias.unlink(); alias.symlink_to('helper')
            binary.rename(directory/'renamed'); self.assertNotEqual(original, runtime.fingerprint(paths)); (directory/'renamed').rename(binary)
            (root/'absent').mkdir(); self.assertNotEqual(original, runtime.fingerprint(paths))

    def test_output_inventory_includes_code_data_layout_and_helper_aliases(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary)/'TurtleGit.app'; contents = app/'Contents'
            (contents/'MacOS').mkdir(parents=True)
            code = contents/'MacOS/TurtleGitRuntime-fixture'; code.write_bytes(b'code')
            (contents/'Resources/TurtleGitRuntimes/Fixture').mkdir(parents=True)
            data = contents/'Resources/TurtleGitRuntimes/Fixture/LICENSE'; data.write_text('license')
            (contents/'Helpers').mkdir(); alias = contents/'Helpers/Fixture'; alias.symlink_to('../Resources/TurtleGitRuntimes/Fixture')
            layout = contents/'Resources/runtime-layout.json'; layout.write_text('{}')
            original = runtime.fingerprint(runtime.output_paths(app))
            for entry in [code, data, layout]:
                before = entry.read_bytes(); entry.write_bytes(before + b'change')
                self.assertNotEqual(original, runtime.fingerprint(runtime.output_paths(app))); entry.write_bytes(before)
            code.unlink(); self.assertNotEqual(original, runtime.fingerprint(runtime.output_paths(app)))

    def test_corrupt_or_unknown_receipts_are_misses(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)/'receipt'
            self.assertIsNone(runtime.load_receipt(path))
            for value in ['invalid', '[]', '{"version": 9}']:
                path.write_text(value); self.assertIsNone(runtime.load_receipt(path))

    def test_explicit_source_alias_hashes_resolved_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source = root/'source'; source.mkdir()
            binary = source/'helper'; binary.write_bytes(b'original')
            alias = root/'kit'; alias.symlink_to('source')
            before = runtime.fingerprint({'kit': alias}, follow_roots=True)
            binary.write_bytes(b'changed')
            self.assertNotEqual(before, runtime.fingerprint({'kit': alias}, follow_roots=True))

    def test_container_permissions_and_replaced_ancestors_cannot_hide_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); app = root/'TurtleGit.app'
            for name in ['Resources','MacOS','Frameworks']: (app/'Contents'/name).mkdir(parents=True, exist_ok=True)
            before = runtime.parent_structure(app)
            (app/'Contents/MacOS/TurtleGit').write_bytes(b'changed application code')
            self.assertEqual(before, runtime.parent_structure(app))
            resources = app/'Contents/Resources'; resources.chmod(0o700)
            self.assertNotEqual(before, runtime.parent_structure(app))
            resources.rmdir(); external = root/'external'; external.mkdir(); resources.symlink_to(external)
            with self.assertRaises(RuntimeError): runtime.parent_structure(app)

if __name__ == '__main__': unittest.main()
