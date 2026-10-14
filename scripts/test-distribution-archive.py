#!/usr/bin/env python3
"""Archive identity, containment, symbol matching and offline-only export contracts."""
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
from distribution_archive import archive_application, file_inventory, debug_symbols, export_options
from bundle_architectures import APPLICATION_CODE

class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory(prefix='TurtleGitArchiveQA-')
        self.root=Path(self.directory.name).resolve()/'Candidate.xcarchive'
        self.app=self.root/'Products/Applications/TurtleGitMac.app'
        (self.app/'Contents').mkdir(parents=True)
        self.info={'CFBundleIdentifier':'org.turtlegit.macos','CFBundleVersion':'1','CFBundleShortVersionString':'0.1','CFBundlePackageType':'APPL'}
        (self.app/'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        self.metadata={'ArchiveVersion':2,'ApplicationProperties':{'ApplicationPath':'Applications/TurtleGitMac.app',**self.info}}
        self.save()
    def tearDown(self):self.directory.cleanup()
    def save(self):(self.root/'Info.plist').write_bytes(plistlib.dumps(self.metadata))
    def test_identity_and_extra_installed_products(self):
        self.assertEqual(archive_application(self.root)[0],self.app)
        (self.root/'Products/Library').mkdir()
        with self.assertRaisesRegex(ValueError,'extra installed'):archive_application(self.root)
        (self.root/'Products/Library').rmdir()
        self.metadata['ApplicationProperties']['CFBundleVersion']='2';self.save()
        with self.assertRaisesRegex(ValueError,'identity mismatch'):archive_application(self.root)
    def test_archive_paths_and_metadata_cannot_escape(self):
        for path in ['/Applications/Other.app','../Outside.app','Applications/../Outside.app']:
            self.metadata['ApplicationProperties']['ApplicationPath']=path;self.save()
            with self.assertRaises(ValueError):archive_application(self.root)
    def test_inventory_preserves_contained_alias_and_rejects_escaping_alias(self):
        data=self.app/'Contents/source.txt';data.write_text('retained source/license')
        alias=self.app/'Contents/alias';alias.symlink_to('source.txt')
        manifest=file_inventory(self.root)
        self.assertEqual(manifest['Products/Applications/TurtleGitMac.app/Contents/alias']['target'],'source.txt')
        self.assertIn('sha256',manifest['Products/Applications/TurtleGitMac.app/Contents/source.txt'])
        alias.unlink();outside=Path(self.directory.name)/'outside';outside.write_text('outside');alias.symlink_to(outside)
        with self.assertRaisesRegex(ValueError,'escaping'):file_inventory(self.root)
    def test_matching_symbols_required_for_every_owned_code_binary(self):
        for relative in APPLICATION_CODE:
            binary=self.app/relative;binary.parent.mkdir(parents=True,exist_ok=True);binary.write_bytes(b'code')
            symbols=self.root/'dSYMs'/(binary.name+'.dSYM')/'Contents/Resources/DWARF'/binary.name
            symbols.parent.mkdir(parents=True);symbols.write_bytes(b'symbols')
        values={'arm64':'AAAAAAAA-0000-0000-0000-000000000000','x86_64':'BBBBBBBB-0000-0000-0000-000000000000'}
        with patch('distribution_archive.uuid_map',return_value=values):self.assertEqual(len(debug_symbols(self.root,self.app)),8)
        helper=self.app/'Contents/Helpers/SSHAskpass/TurtleGitSSHAskpass'
        relocated=helper.with_name('TurtleGitRuntime-SSHAskpass-hash-TurtleGitSSHAskpass')
        helper.rename(relocated);helper.symlink_to(relocated.name)
        with patch('distribution_archive.uuid_map',return_value=values):self.assertEqual(len(debug_symbols(self.root,self.app)),8)
        missing=next((self.root/'dSYMs').glob('*.dSYM/Contents/Resources/DWARF/*'));missing.unlink()
        with patch('distribution_archive.uuid_map',return_value=values):
            with self.assertRaisesRegex(ValueError,'mismatched universal'):debug_symbols(self.root,self.app)
    def test_export_settings_require_actual_team_and_never_upload(self):
        for value in [None,'TEAM_ID_HERE','abcdefghij','ABC123']:
            with self.assertRaises(ValueError):export_options('AppStore',value)
        options=export_options('AppStore','ABCD123456')
        self.assertEqual(options['method'],'app-store-connect');self.assertEqual(options['destination'],'export')
        self.assertFalse(options['manageAppVersionAndBuildNumber']);self.assertFalse(options['uploadSymbols'])
        self.assertEqual(export_options('Release','ABCD123456')['method'],'developer-id')

if __name__=='__main__':unittest.main()
