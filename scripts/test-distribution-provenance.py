#!/usr/bin/env python3
"""Distribution provenance acceptance without compiling, signing or launching apps."""
import copy
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from distribution_archive import file_inventory
from distribution_provenance import source_inputs, require_same_inputs, verify_candidate


class ProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='TurtleGitProvenance-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'Sources').mkdir(); (self.root / 'docs').mkdir()
        (self.root / 'Sources/main.swift').write_text('original')
        (self.root / 'docs/guide.md').write_text('guide')
        self.git('init', '-q'); self.git('add', '.')
        self.git('-c', 'user.name=Provenance Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'base')
        self.app = self.root / 'candidate.app'; (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/Resources').mkdir()
        (self.app / 'Contents/MacOS/app').write_bytes(b'code')
        (self.app / 'Contents/Resources/help').write_bytes(b'help')
        (self.app / 'Contents/Alias').symlink_to('Resources/help')
        self.audit = {'build_inputs': source_inputs(self.root), 'bundle_files': file_inventory(self.app)}

    def git(self, *arguments):
        environment = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0')
        return subprocess.check_output(['git', '-C', str(self.root), *arguments], env=environment, stderr=subprocess.DEVNULL)

    def testUnchangedCandidateAndDocsOnlyCommitRetainOriginalBuildRevision(self):
        built = self.audit['build_inputs']['git_head_at_measurement']
        verify_candidate(self.audit, self.root, self.app)
        (self.root / 'docs/guide.md').write_text('updated guide')
        self.git('add', 'docs'); self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'docs')
        current = verify_candidate(self.audit, self.root, self.app)
        self.assertNotEqual(current['git_head_at_measurement'], built)
        self.assertEqual(self.audit['build_inputs']['git_head_at_measurement'], built)

    def testTrackedAndUntrackedBuildEditsCannotReuseAudit(self):
        (self.root / 'Sources/main.swift').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'inputs changed'): verify_candidate(self.audit, self.root, self.app)
        (self.root / 'Sources/main.swift').write_text('original')
        (self.root / 'Sources/new file.swift').write_text('new')
        current = source_inputs(self.root)
        self.assertTrue(current['dirty_inputs'])
        with self.assertRaises(ValueError): require_same_inputs(self.audit['build_inputs'], current)

    def testSourceAliasReferentContentCannotChangeUnnoticed(self):
        referent = self.root / 'generated.swift'; referent.write_text('first')
        alias = self.root / 'Sources/alias.swift'; alias.symlink_to('../generated.swift')
        measured = source_inputs(self.root); referent.write_text('second')
        with self.assertRaises(ValueError): require_same_inputs(measured, source_inputs(self.root))
        alias.unlink(); alias.symlink_to('/dev/null')
        with self.assertRaises(ValueError): source_inputs(self.root)

    def testResourceDriftCannotPassWithUnchangedExecutable(self):
        (self.app / 'Contents/Resources/help').write_bytes(b'changed help')
        with self.assertRaisesRegex(ValueError, 'bundle changed'): verify_candidate(self.audit, self.root, self.app)

    def testModesAliasesAndExtraMembersAreMeasured(self):
        executable = self.app / 'Contents/MacOS/app'; previous = executable.stat().st_mode
        executable.chmod(0o700)
        with self.assertRaises(ValueError): verify_candidate(self.audit, self.root, self.app)
        executable.chmod(previous)
        (self.app / 'Contents/extra').write_text('extra')
        with self.assertRaises(ValueError): verify_candidate(self.audit, self.root, self.app)
        (self.app / 'Contents/extra').unlink(); (self.app / 'Contents/Alias').unlink()
        (self.app / 'Contents/Alias').symlink_to('MacOS/app')
        with self.assertRaises(ValueError): verify_candidate(self.audit, self.root, self.app)

    def testOldOrIncompleteAuditCannotBeRelabelled(self):
        for value in [{}, {'build_inputs': self.audit['build_inputs']}, {'bundle_files': self.audit['bundle_files']}]:
            with self.assertRaises(ValueError): verify_candidate(value, self.root, self.app)
        altered = copy.deepcopy(self.audit); altered['build_inputs']['sha256'] = 'not measured'
        with self.assertRaises(ValueError): verify_candidate(altered, self.root, self.app)

    def testDeletedInputAndEscapingBundleAliasAreRejected(self):
        (self.root / 'Sources/main.swift').unlink()
        with self.assertRaises(ValueError): verify_candidate(self.audit, self.root, self.app)
        (self.root / 'Sources/main.swift').write_text('original')
        (self.app / 'Contents/Alias').unlink(); (self.app / 'Contents/Alias').symlink_to(self.root / 'docs/guide.md')
        with self.assertRaises(ValueError): verify_candidate(self.audit, self.root, self.app)


if __name__ == '__main__': unittest.main()
