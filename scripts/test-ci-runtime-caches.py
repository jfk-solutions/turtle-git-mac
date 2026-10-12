#!/usr/bin/env python3
"""Verify cache invalidation and fail-closed handling of captured dependencies."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('runtime_cache', ROOT / 'scripts/ci-runtime-cache-key.py')
cache = importlib.util.module_from_spec(spec); spec.loader.exec_module(cache)

class RuntimeCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='TurtleGitCacheKeys-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.recipes = json.loads((ROOT / 'Configuration/CIRuntimeCaches.json').read_text())
        inputs = {'Configuration/CIRuntimeCaches.json', 'scripts/ci-runtime-cache-key.py'} | {value for recipe in self.recipes.values() for value in recipe['inputs']}
        for name in inputs:
            path = self.root / name; path.parent.mkdir(parents=True, exist_ok=True)
            # Transferred components are represented by fixture bytes here;
            # actual prepared payload validators run separately.
            source = ROOT / name
            path.write_bytes(source.read_bytes() if source.is_file() else ('captured dependency:' + name).encode())
    def key(self, name, toolchain='sdk/compiler fingerprint', runner='macOS-X64'):
        return cache.key(name, toolchain, runner, root=self.root)
    def testDeterministicKeysChangeWithToolchainAndRunner(self):
        for name in self.recipes:
            with self.subTest(runtime=name):
                key = self.key(name)
                self.assertEqual(key, self.key(name))
                self.assertTrue(key.startswith('runtime-' + name + '-v1-'))
                self.assertNotEqual(key, self.key(name, toolchain='different SDK'))
                self.assertNotEqual(key, self.key(name, runner='macOS-ARM64'))
    def testEveryDeclaredInputInvalidatesOnlyItsDependentKeys(self):
        originals = {name: self.key(name) for name in self.recipes}
        for value in {path for recipe in self.recipes.values() for path in recipe['inputs']}:
            with self.subTest(input=value):
                path = self.root / value; old = path.read_bytes(); path.write_bytes(old + b'changed')
                for name, recipe in self.recipes.items():
                    self.assertEqual(self.key(name) != originals[name], value in recipe['inputs'])
                path.write_bytes(old)
    def testMissingTransitiveManifestOrHeaderRefusesAKey(self):
        for name in ['git', 'merge-diff']:
            for value in self.recipes[name]['inputs']:
                if value.startswith('build/'):
                    with self.subTest(runtime=name, input=value):
                        path = self.root / value; data = path.read_bytes(); path.unlink()
                        with self.assertRaises(FileNotFoundError): self.key(name)
                        path.write_bytes(data)
    def testApplicationEditsDoNotRebuildUnchangedRuntime(self):
        originals = {name: self.key(name) for name in self.recipes}
        path = self.root / 'Sources/TurtleGitMac/CommitDialog.swift'; path.parent.mkdir(parents=True)
        path.write_text('new native dialog implementation')
        self.assertEqual(originals, {name: self.key(name) for name in self.recipes})
    def testWorkflowOrdersRestoreBuildValidateSaveWithoutPrefixFallback(self):
        workflow = (ROOT / '.github/workflows/macos.yml').read_text()
        self.assertNotIn('restore-keys:', workflow)
        for name, recipe in self.recipes.items():
            start = workflow.index('      - name: Capture ' + name + ' runtime cache key')
            save = workflow.index('      - name: Save validated ' + name + ' runtime', start)
            end = workflow.find('\n      - ', save + 1)
            section = workflow[start:end]
            self.assertLess(section.index('actions/cache/restore@v5'), section.index("if: steps." + name + "-cache.outputs.cache-hit != 'true'"))
            self.assertLess(section.index('Validate prepared or restored'), section.index('actions/cache/save@v5'))
            self.assertEqual(section.count('path: ' + recipe['path']), 2)
            self.assertIn('run: ' + ' '.join(recipe['validate']), section)
            self.assertIn('steps.' + name + '-cache.outputs.cache-primary-key', section)
            self.assertNotIn('if:', section[section.index('      - name: Validate prepared or restored'):section.index('      - name: Save validated')])

if __name__ == '__main__': unittest.main()
