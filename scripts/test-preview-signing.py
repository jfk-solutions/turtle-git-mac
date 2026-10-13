#!/usr/bin/env python3
"""Preview inventories must preserve runtime hashes and sign auxiliary code first."""
from pathlib import Path
import plistlib
import tempfile
import unittest
from preview_signing import signing_plan

class PreviewSigningTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='TurtleGitPreviewSigning-')
        self.root = Path(self.directory.name).resolve()
        self.app = self.bundle(self.root / 'Preview.app', 'Preview')
    def tearDown(self): self.directory.cleanup()
    def code(self, path):
        path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(bytes.fromhex('cffaedfe') + b'fixture')
        return path
    def bundle(self, path, name):
        self.code(path / 'Contents/MacOS' / name)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': name}))
        return path
    def test_auxiliary_macos_code_is_signed_before_container_main(self):
        preview = self.code(self.app / 'Contents/MacOS/__preview.dylib')
        debug = self.code(self.app / 'Contents/MacOS/Preview.debug.dylib')
        extension = self.bundle(self.app / 'Contents/PlugIns/Finder.appex', 'Finder')
        finder_preview = self.code(extension / 'Contents/MacOS/__preview.dylib')
        payloads, bundles = signing_plan(self.app)
        self.assertEqual(set(payloads), {preview, debug, finder_preview})
        self.assertEqual(bundles, [extension, self.app])
    def test_versioned_framework_main_alias_is_not_individually_resigned(self):
        framework = self.app / 'Contents/Frameworks/Core.framework'
        version = framework / 'Versions/A'
        self.code(version / 'Core'); auxiliary = self.code(version / 'Core.debug.dylib')
        (version / 'Resources').mkdir(); (version / 'Resources/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Core'}))
        (framework / 'Versions/Current').symlink_to('A')
        (framework / 'Resources').symlink_to('Versions/Current/Resources')
        (framework / 'Core').symlink_to('Versions/Current/Core')
        payloads, bundles = signing_plan(self.app)
        self.assertEqual(payloads, [auxiliary]); self.assertEqual(bundles, [framework, self.app])
    def test_finalized_runtime_payloads_and_data_are_preserved(self):
        runtime = self.code(self.app / 'Contents/Helpers/Git/bin/git')
        auxiliary = self.code(self.app / 'Contents/MacOS/__preview.dylib')
        data = self.app / 'Contents/Resources/source.txt'; data.parent.mkdir(exist_ok=True); data.write_text('source license')
        payloads, _ = signing_plan(self.app, {'Helpers/Git/bin/git'})
        self.assertEqual(payloads, [auxiliary]); self.assertNotIn(runtime, payloads)
    def test_bundle_executable_and_metadata_cannot_escape_the_copy(self):
        plist = self.app / 'Contents/Info.plist'
        plist.write_bytes(plistlib.dumps({'CFBundleExecutable':'../outside'}))
        with self.assertRaises(ValueError): signing_plan(self.app)
        plist.write_bytes(plistlib.dumps({'CFBundleExecutable':'Preview'}))
        executable = self.app / 'Contents/MacOS/Preview'; executable.unlink(); executable.symlink_to(self.code(self.root / 'outside'))
        with self.assertRaises(ValueError): signing_plan(self.app)
        executable.unlink(); self.code(executable)
        outside_plist = self.root / 'outside-info.plist'
        outside_plist.write_bytes(plistlib.dumps({'CFBundleExecutable':'Preview'}))
        plist.unlink(); plist.symlink_to(outside_plist)
        with self.assertRaises(ValueError): signing_plan(self.app)

if __name__ == '__main__': unittest.main()
