#!/usr/bin/env python3
"""Focused workflow syntax, exact coverage and failure-aggregation regressions."""
import copy
import importlib.util
import json
import os
import subprocess
import unittest

from pathlib import Path
spec = importlib.util.spec_from_file_location('macos_lanes', Path(__file__).with_name('check-macos-ci-lanes.py'))
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)

class MacOSLaneTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.inventory = json.loads(ci.INVENTORY.read_text())
        cls.originals = ci.original_steps(cls.inventory)
        cls.workflow = ci.yaml_document(ci.WORKFLOW.read_text())
    def verify(self, workflow=None, inventory=None):
        return ci.verify(workflow or self.workflow, inventory or self.inventory, self.originals)
    def testCurrentSyntaxAndExactOriginalCoverage(self):
        self.verify()
    def testMissingDuplicateAndUnknownStepsRefused(self):
        for operation in ['remove', 'duplicate', 'unknown']:
            value = copy.deepcopy(self.workflow); steps = value['jobs']['validation']['steps']
            if operation == 'remove': steps.pop()
            if operation == 'duplicate': steps.append(copy.deepcopy(steps[-1]))
            if operation == 'unknown': steps.append({'name': 'Unmapped new check', 'run': 'true'})
            with self.subTest(operation=operation), self.assertRaises(AssertionError): self.verify(value)
    def testCommandsEnvironmentsActionsAndConditionsCannotDrift(self):
        for field in ['run', 'env', 'if', 'uses', 'with']:
            value = copy.deepcopy(self.workflow)
            step = next(s for s in value['jobs']['validation']['steps'][2:] if field in s)
            step[field] = 'changed' if field not in ['env', 'with'] else {'changed': 'value'}
            with self.subTest(field=field), self.assertRaises(AssertionError): self.verify(value)
    def testReorderedStepsAndUnknownLaneRefused(self):
        value = copy.deepcopy(self.workflow); steps = value['jobs']['validation']['steps']; steps[-1],steps[-2] = steps[-2],steps[-1]
        with self.assertRaises(AssertionError): self.verify(value)
        inventory = copy.deepcopy(self.inventory); inventory['steps'][-1]['lane'] = 'unmapped'
        with self.assertRaises(AssertionError): self.verify(inventory=inventory)
    def testProducerConsumerCannotMoveEvenWithMatchingInventory(self):
        for name in ['Working copy revision utility and upstream templates', 'Native AppStore bundled SSH encrypted-key loading and cleanup']:
            value = copy.deepcopy(self.workflow); inventory = copy.deepcopy(self.inventory)
            record = next(item for item in inventory['steps'] if item['name'] == name); record['lane'] = 'editors'
            step = next(s for s in value['jobs']['validation']['steps'] if s.get('name') == name); step['if'] = "matrix.lane == 'editors'"
            with self.subTest(name=name), self.assertRaises(AssertionError): self.verify(value, inventory)
    def testEveryLaneBuildsEditorBeforeEarliestNativeOrCoreConsumer(self):
        steps = self.workflow['jobs']['validation']['steps']
        setup_index = next(i for i, step in enumerate(steps) if step.get('name') == ci.EDITOR_SETUP['name'])
        self.assertEqual(steps[setup_index], ci.EDITOR_SETUP)
        self.assertEqual(steps[setup_index - 1]['name'], 'Application and embedded Finder extension')
        for name in ['Git integration tests', 'Native Commit and Rebase encoding receiver',
                     'Native Commit and Rebase message-file receiver', 'Native remembered Commit button actions',
                     'Grouped native references, Worktrees, Revision Graph, pickers, settings, Commit, SVN and external Merge lifecycle',
                     'Native Cherry Pick and Rebase recovery across Git versions']:
            self.assertLess(setup_index, next(i for i, step in enumerate(steps) if step.get('name') == name), name)
        for mutation in ['remove', 'conditional', 'late']:
            value = copy.deepcopy(self.workflow); changed = value['jobs']['validation']['steps']
            if mutation == 'remove': changed.pop(setup_index)
            if mutation == 'conditional': changed[setup_index]['if'] = "matrix.lane == 'distribution'"
            if mutation == 'late': changed.append(changed.pop(setup_index))
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError): self.verify(value)
    def testMetafileFailureEvidenceHasExactOwnerAndPlacement(self):
        steps = self.workflow['jobs']['validation']['steps']
        indexes = [i for i, step in enumerate(steps)
                   if step.get('name') == ci.METAFILE_FAILURE_EVIDENCE['name']]
        self.assertEqual(len(indexes), 1)
        index = indexes[0]
        self.assertEqual(steps[index], ci.METAFILE_FAILURE_EVIDENCE)
        self.assertEqual(steps[index - 1]['name'], ci.METAFILE_CONSUMER)
        self.verify()
    def testMetafileFailureEvidenceMissingDuplicateMovedAndRenamedRefused(self):
        for mutation in ['missing', 'duplicate', 'before-producer', 'late', 'renamed']:
            value = copy.deepcopy(self.workflow); steps = value['jobs']['validation']['steps']
            index = next(i for i, step in enumerate(steps)
                         if step.get('name') == ci.METAFILE_FAILURE_EVIDENCE['name'])
            if mutation == 'missing': steps.pop(index)
            if mutation == 'duplicate': steps.insert(index + 1, copy.deepcopy(steps[index]))
            if mutation == 'before-producer': steps.insert(index - 1, steps.pop(index))
            if mutation == 'late': steps.append(steps.pop(index))
            if mutation == 'renamed': steps[index]['name'] = 'Uninventoried metafile artifact'
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError): self.verify(value)
    def testMetafileEvidenceCannotRunForSuccessOrAnotherLane(self):
        for condition in ["matrix.lane == 'commit-repository'", 'failure()', 'always()',
                          "matrix.lane == 'images-documents' && failure()",
                          "matrix.lane == 'commit-repository' && success()",
                          "matrix.lane == 'commit-repository' || failure()"]:
            value = copy.deepcopy(self.workflow)
            step = next(s for s in value['jobs']['validation']['steps']
                        if s.get('name') == ci.METAFILE_FAILURE_EVIDENCE['name'])
            step['if'] = condition
            with self.subTest(condition=condition), self.assertRaises(AssertionError): self.verify(value)
    def testMetafileEvidenceActionAndConstrainedPathsCannotDrift(self):
        mutations = {
            'action-version': lambda s: s.update(uses='actions/upload-artifact@v3'),
            'another-action': lambda s: s.update(uses='another/upload@v4'),
            'artifact-name': lambda s: s['with'].update(name='metafile-pixel-evidence'),
            'broad-path': lambda s: s['with'].update(path='build/**\n'),
            'extra-path': lambda s: s['with'].update(path=s['with']['path']+'**\n'),
            'missing-path': lambda s: s['with'].update(path='\n'.join(s['with']['path'].splitlines()[:2])+'\n'),
            'missing-file-policy': lambda s: s['with'].update({'if-no-files-found': 'error'}),
            'extra-upload-setting': lambda s: s['with'].update({'include-hidden-files': True}),
            'extra-command': lambda s: s.update(run='true'),
            'extra-environment': lambda s: s.update(env={'UNREVIEWED': 'value'}),
        }
        for name, mutate in mutations.items():
            value = copy.deepcopy(self.workflow)
            step = next(s for s in value['jobs']['validation']['steps']
                        if s.get('name') == ci.METAFILE_FAILURE_EVIDENCE['name'])
            mutate(step)
            with self.subTest(mutation=name), self.assertRaises(AssertionError): self.verify(value)
    def testMetafileDiagnosticAdditionCannotHideProducerChanges(self):
        for field, replacement in [('run', 'true'), ('if', "matrix.lane == 'images-documents'"),
                                   ('env', {'UNREVIEWED': 'value'})]:
            value = copy.deepcopy(self.workflow)
            step = next(s for s in value['jobs']['validation']['steps']
                        if s.get('name') == ci.METAFILE_CONSUMER)
            step[field] = replacement
            with self.subTest(field=field), self.assertRaises(AssertionError): self.verify(value)
    def testNoFailFastCancellationOrMissingAggregate(self):
        for change in ['fail-fast', 'aggregate', 'cancel', 'timeout']:
            value = copy.deepcopy(self.workflow)
            if change == 'fail-fast': value['jobs']['validation']['strategy']['fail-fast'] = True
            if change == 'aggregate': value['jobs']['build-and-test']['if'] = 'success()'
            if change == 'cancel': value['concurrency']['cancel-in-progress'] = True
            if change == 'timeout': del value['jobs']['validation']['timeout-minutes']
            with self.subTest(change=change), self.assertRaises(AssertionError): self.verify(value)
    def testActualAggregateFailsOnFailureCancellationAndSkippedProducers(self):
        shell = self.workflow['jobs']['build-and-test']['steps'][0]['run']
        for job in ['svn-runtime', 'validation']:
            for status in ['success', 'failure', 'cancelled', 'skipped']:
                results = {name: {'result': 'success'} for name in ['svn-runtime', 'validation']}; results[job]['result'] = status
                result = subprocess.run(['bash', '-e', '-c', shell], env=dict(os.environ, NEEDS_JSON=json.dumps(results)), capture_output=True, text=True)
                with self.subTest(job=job, status=status): self.assertEqual(result.returncode == 0, status == 'success', result.stderr)
    def testOriginalSVNProducerUnchangedExceptExplicitTimeout(self):
        # Its complete source is pinned in the baseline verification; here guard
        # the producer artifact required by every matrix worker as well.
        producer = self.workflow['jobs']['svn-runtime']
        upload = producer['steps'][-1]
        download = next(s for s in self.workflow['jobs']['validation']['steps'] if s.get('uses') == 'actions/download-artifact@v4')
        self.assertEqual(upload['with']['name'], download['with']['name'])
        self.assertEqual(upload['with']['path'], 'build/git-svn-runtime/GitSVN.tar.gz')

if __name__ == '__main__': unittest.main()
