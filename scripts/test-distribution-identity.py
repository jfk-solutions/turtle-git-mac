#!/usr/bin/env python3
"""Offline measured release identity and explicit build parameter contracts."""
from pathlib import Path
import plistlib
import tempfile
import unittest
from distribution_identity import application_identity, build_number, positive_jobs


class DistributionIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='TurtleGitReleaseIdentityQA-')
        self.app = Path(self.temporary.name) / 'TurtleGitMac.app'
        self.paths = {
            'application': self.app / 'Contents/Info.plist',
            'finder': self.app / 'Contents/PlugIns/TurtleGitFinder.appex/Contents/Info.plist',
            'cache': self.app / 'Contents/Library/LaunchServices/TurtleGitCache.app/Contents/Info.plist',
        }
        self.values = {}
        for role, path in self.paths.items():
            path.parent.mkdir(parents=True)
            self.values[role] = {'CFBundleIdentifier': 'org.turtlegit.macos' + ('' if role == 'application' else '.' + role),
                                 'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '2'}
            self.save(role)

    def tearDown(self):
        self.temporary.cleanup()

    def save(self, role):
        self.paths[role].write_bytes(plistlib.dumps(self.values[role]))

    def test_actual_all_peer_versions_match_and_requested_number_is_measured(self):
        value = application_identity(self.app, expected_build_number='2')
        self.assertEqual(value['build_number'], '2')
        self.assertEqual(value['marketing_version'], '0.1.0')
        self.assertEqual(set(value['peers']), {'finder', 'cache'})
        with self.assertRaisesRegex(ValueError, 'Requested build number'):
            application_identity(self.app, expected_build_number='3')
        for role in self.paths:
            self.values[role]['CFBundleVersion'] = '20.7.3'; self.save(role)
        self.assertEqual(application_identity(self.app, '20.7.3')['build_number'], '20.7.3')

    def test_peer_version_build_or_identifier_mismatch_is_rejected(self):
        for role in ['finder', 'cache']:
            for key, changed in [('CFBundleVersion', '1'), ('CFBundleShortVersionString', '0.2.0'),
                                 ('CFBundleIdentifier', 'org.unrelated.peer')]:
                with self.subTest(role=role, key=key):
                    original = self.values[role][key]
                    self.values[role][key] = changed; self.save(role)
                    with self.assertRaisesRegex(ValueError, 'mismatch'):
                        application_identity(self.app)
                    self.values[role][key] = original; self.save(role)

    def test_missing_unexpanded_and_aliased_identity_metadata_are_rejected(self):
        original = self.paths['finder'].read_bytes()
        self.paths['finder'].unlink()
        with self.assertRaises(FileNotFoundError):
            application_identity(self.app)
        self.paths['finder'].write_bytes(original)
        self.values['finder']['CFBundleVersion'] = '$(CURRENT_PROJECT_VERSION)'; self.save('finder')
        with self.assertRaises(ValueError):
            application_identity(self.app)
        self.paths['finder'].unlink()
        outside = Path(self.temporary.name) / 'outside.plist'; outside.write_bytes(original)
        self.paths['finder'].symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'alias'):
            application_identity(self.app)

    def test_current_apple_numeric_grammar_accepts_zero_without_obsolete_digit_caps(self):
        for value in ['0', '2', '2.0', '20.7.3', '12345678.12345.99999']:
            self.assertEqual(build_number(value), value)
        for value in ['', '2.', '.2', '2..1', '1.2.3.4', '-2', '+2', '2beta', ' 2', '2\n', '２', 2, None]:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    build_number(value)

    def test_build_parallelism_requires_positive_integer(self):
        for value in [1, 4, '2', '12']:
            self.assertEqual(positive_jobs(value), int(value))
        for value in [0, -1, '0', '-2', '2.0', 'abc', '', None, True, 1.5]:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    positive_jobs(value)


if __name__ == '__main__':
    unittest.main()
