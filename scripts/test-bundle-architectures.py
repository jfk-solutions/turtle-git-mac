#!/usr/bin/env python3
"""Verify the architecture audit against real compiled thin/universal Mach-O files."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from bundle_architectures import APPLICATION_CODE, audit_application_architectures

class BundleArchitectureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory(prefix='TurtleGitArchitecture-')
        cls.root = Path(cls.fixture.name)
        source = cls.root / 'main.c'
        source.write_text('int main(void) { return 0; }\n')
        cls.thin = cls.root / 'thin'
        cls.universal = cls.root / 'universal'
        subprocess.run(['xcrun','clang','-arch','arm64','-mmacosx-version-min=13.0',str(source),'-o',str(cls.thin)],check=True)
        subprocess.run(['xcrun','clang','-arch','arm64','-arch','x86_64','-mmacosx-version-min=13.0',str(source),'-o',str(cls.universal)],check=True)
    @classmethod
    def tearDownClass(cls): cls.fixture.cleanup()
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir=self.root)
        self.app = Path(self.directory.name) / 'TurtleGit.app'
        for relative in APPLICATION_CODE:
            target = self.app / relative
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(self.universal,target)
    def tearDown(self): self.directory.cleanup()
    def test_all_owned_targets_require_both_architectures(self):
        result = audit_application_architectures(self.app)
        self.assertEqual(set(result),set(APPLICATION_CODE))
        for slices in result.values(): self.assertEqual(set(slices),{'arm64','x86_64'})
        for relative in APPLICATION_CODE:
            with self.subTest(target=relative):
                target = self.app / relative
                shutil.copy2(self.thin,target)
                with self.assertRaisesRegex(ValueError,relative.replace('.',r'\.')):
                    audit_application_architectures(self.app)
                shutil.copy2(self.universal,target)
    def test_missing_and_escaped_payloads_fail(self):
        target = self.app / APPLICATION_CODE[-1]
        target.unlink()
        with self.assertRaises(FileNotFoundError): audit_application_architectures(self.app)
        target.symlink_to(self.universal)
        with self.assertRaisesRegex(ValueError,'escapes'): audit_application_architectures(self.app)

if __name__ == '__main__': unittest.main()
