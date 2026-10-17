#!/usr/bin/env python3
"""Native catalog conversion contracts; no application launch or network."""
import importlib.util
from pathlib import Path
import unittest
spec = importlib.util.spec_from_file_location('build_localizations', Path(__file__).with_name('build-localizations.py'))
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)

class LocalizationContracts(unittest.TestCase):
    def test_multiline_unicode_and_context(self):
        text = 'msgctxt "one"\nmsgid "Open "\n"file"\nmsgstr "Datei "\n"öffnen"\n\n'
        self.assertEqual(module.parse_po(text), [('Open file','Datei öffnen')])
    def test_fuzzy_plural_obsolete_and_header_do_not_become_labels(self):
        text = '#, fuzzy, c-format\nmsgid "Open"\nmsgstr "wrong"\n\nmsgid "file"\nmsgid_plural "files"\n"continued"\nmsgstr[0] "Datei"\nmsgstr[1] "Dateien"\n\n#~ msgid "Gone"\n#~ msgstr "Weg"\n\nmsgid ""\nmsgstr "Language: de\\n"\n\nmsgid "Cancel"\nmsgstr "Abbrechen"\n'
        self.assertEqual(module.parse_po(text), [('Cancel','Abbrechen')])
    def test_mnemonics_literal_ampersands_shortcuts_and_branding(self):
        self.assertEqual(module.label('&Open && Close\tCtrl+O'),'Open & Close')
        self.assertEqual(module.label('About TortoiseGit'),'About TurtleGit for Mac')
        self.assertEqual(module.label('TortoiseGitMerge'),'TortoiseGitMerge')
    def test_native_ellipsis_and_navigation_aliases(self):
        self.assertIn(('Settings…','Einstellungen…'),module.variants('&Settings...','&Einstellungen'))
        self.assertIn(('Next','Nächste'),module.variants('&Next >','&Nächste >'))
        self.assertIn(('Back','Zurück'),module.variants('< &Back','< &Zurück'))
    def test_malformed_po_is_refused(self):
        with self.assertRaises(ValueError):module.parse_po('not a directive\n')
        with self.assertRaises((ValueError,SyntaxError)):module.parse_po('msgid "unterminated\n')
if __name__ == '__main__':unittest.main()
