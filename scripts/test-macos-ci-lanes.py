#!/usr/bin/env python3
"""Focused workflow syntax, exact coverage and failure-aggregation regressions."""
import copy
import ast
import fnmatch
import importlib.util
import json
import os
import re
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
    def eligible(self, name, lane, outcomes=None, cancelled=False):
        step = next(s for s in self.workflow['jobs']['validation']['steps'] if s.get('name') == name)
        expression = step['if']
        self.assertTrue(expression.startswith('${{ ') and expression.endswith(' }}'))
        self.assertIn('!cancelled()', expression)
        values = {'native_ready': 'success', 'store_ready': 'success', 'replay_ready': 'success'}
        values.update(outcomes or {})
        expression = expression[4:-3].replace('!cancelled()', repr(not cancelled))
        expression = expression.replace('matrix.lane', repr(lane)).replace('&&', ' and ')
        expression = re.sub(r'steps\.(\w+)\.outcome', lambda m: repr(values.get(m[1], '')), expression)
        tree = ast.parse(expression.strip(), mode='eval')
        allowed = (ast.Expression, ast.BoolOp, ast.And, ast.Compare, ast.Eq, ast.Constant)
        self.assertTrue(all(isinstance(node, allowed) for node in ast.walk(tree)))
        return eval(compile(tree, '<actual workflow condition>', 'eval'), {'__builtins__': {}})
    def testIndependentConsumersRunAfterAnotherNativeFailure(self):
        for name, lane in [('Native regex source list and editor workflows', 'commit-repository'),
                           ('Native standalone reference browser', 'history-references'),
                           ('Image native command family', 'images-documents'),
                           (ci.UTILITY_STARTUP['name'], 'settings-finder')]:
            with self.subTest(name=name):
                self.assertTrue(self.eligible(name, lane, {'earlier_native': 'failure'}))
                self.assertFalse(self.eligible(name, 'unrelated', {'earlier_native': 'failure'}))
                self.assertFalse(self.eligible(name, lane, cancelled=True))
    def testFailedSkippedMissingOrCancelledPreparationCannotLaunchConsumers(self):
        for outcome in ['failure', 'skipped', 'cancelled', '']:
            with self.subTest(outcome=outcome):
                self.assertFalse(self.eligible('Image native command family', 'images-documents', {'native_ready': outcome}))
                self.assertFalse(self.eligible(ci.STORE_BUILD, 'distribution', {'native_ready': outcome}))
    def testCoreSuiteAndItsFilteredFollowupsKeepTheirOriginalFailurePolicy(self):
        # XCTest already collects its case failures. Do not repeatedly rebuild
        # a failed test target through every filtered follow-up command.
        core = {r['name'] for r in self.inventory['steps'] if r['lane'] == 'core'}
        for step in self.workflow['jobs']['validation']['steps']:
            if step.get('name') in core:
                self.assertEqual(step['if'], "matrix.lane == 'core'", step['name'])
    def testStoreAndReplayConsumersRequireActualProducerSuccess(self):
        replay = 'Native Cherry Pick and Rebase recovery across Git versions'
        expected = {
            'Preserve unsigned distribution audit': ['store_ready'],
            'Revision Graph through built Debug and Store frameworks and helpers': ['store_ready'],
            'Native packaged Git SSH client lookup without network': ['store_ready'],
            'Native AppStore bundled SSH encrypted-key loading and cleanup': ['store_ready'],
            replay: ['store_ready', 'replay_ready'],
        }
        self.assertEqual(ci.COLLECTION_DEPENDENCIES, expected)
        for name, dependencies in expected.items():
            self.assertTrue(self.eligible(name, 'distribution'))
            for dependency in dependencies:
                for outcome in ['failure', 'skipped', 'cancelled', '']:
                    with self.subTest(name=name, dependency=dependency, outcome=outcome):
                        self.assertFalse(self.eligible(name, 'distribution', {dependency: outcome}))
        self.assertTrue(self.eligible(ci.REPLAY_BUILD, 'distribution', {'store_ready': 'failure'}))
        self.assertFalse(self.eligible(replay, 'distribution', {'store_ready': 'success', 'replay_ready': 'failure'}))
    def testCollectionConditionsAndProducerIdentitiesCannotBeWeakened(self):
        for mutation in ['implicit-success', 'always', 'drop-ready', 'drop-store', 'drop-replay', 'continue-on-error', 'ready-id', 'store-id', 'replay-id']:
            value = copy.deepcopy(self.workflow); steps = value['jobs']['validation']['steps']
            consumer = next(s for s in steps if s.get('name') == 'Native Cherry Pick and Rebase recovery across Git versions')
            if mutation == 'implicit-success': consumer['if'] = "matrix.lane == 'distribution'"
            if mutation == 'always': consumer['if'] = consumer['if'].replace('!cancelled()', 'always()')
            if mutation == 'drop-ready': consumer['if'] = consumer['if'].replace("steps.native_ready.outcome == 'success' && ", '')
            if mutation == 'drop-store': consumer['if'] = consumer['if'].replace(" && steps.store_ready.outcome == 'success'", '')
            if mutation == 'drop-replay': consumer['if'] = consumer['if'].replace(" && steps.replay_ready.outcome == 'success'", '')
            if mutation == 'continue-on-error': consumer['continue-on-error'] = True
            if mutation.endswith('-id'):
                name = {'ready-id': ci.EDITOR_SETUP['name'], 'store-id': ci.STORE_BUILD, 'replay-id': ci.REPLAY_BUILD}[mutation]
                next(s for s in steps if s.get('name') == name)['id'] = 'unreviewed'
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError): self.verify(value)
    def testDocumentationAdmissionDoesNotFilterPullRequests(self):
        self.assertIsNone(self.workflow['true']['pull_request'])
        for filtering in [{'paths-ignore': ['docs/**']}, {'branches': ['main']},
                          {'types': ['opened']}, {'paths': ['Sources/**']}]:
            value = copy.deepcopy(self.workflow)
            value['true']['pull_request'] = filtering
            with self.subTest(filtering=filtering), self.assertRaises(AssertionError): self.verify(value)
    def testPushAdmissionCannotBroadenToNativeOrReferenceInputs(self):
        # These are real fixture, reference-oracle, generated-resource and
        # distribution inputs; ignoring their broad parents would hide changes.
        for pattern in ['docs/**', 'docs/qa/**/*.json', 'docs/qa/*.swift',
                        'docs/upstream*', 'docs/site/**', 'docs/site/assets/**',
                        'docs/site/assets/application-icon.png', 'docs/site/assets/application-favicon.png',
                        'Sources/**', 'Configuration/**',
                        'Licenses/**', 'LICENSE', 'NOTICE', 'AUTHORS.md']:
            value = copy.deepcopy(self.workflow)
            value['true']['push']['paths-ignore'].append(pattern)
            with self.subTest(pattern=pattern), self.assertRaises(AssertionError): self.verify(value)
        for mutation in [None, {'paths': ['Sources/**']},
                         {'paths-ignore': list(ci.DOCUMENTATION_PUSH_IGNORES), 'branches': ['main']}]:
            value = copy.deepcopy(self.workflow); value['true']['push'] = mutation
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError): self.verify(value)
    def testRealNativeAndOraclePathsRemainOutsideDocumentationPatterns(self):
        patterns = self.workflow['true']['push']['paths-ignore']
        # Concrete consumed paths, not a replacement for GitHub's glob engine.
        critical = ['docs/qa/merge-find-native-2026-10-12.swift',
                    'docs/qa/statistics-palette-reference-2026-10-07.json',
                    'docs/qa/metafile-path-gradient-windows-reference-2026-10-25.json',
                    'docs/upstream.json', 'docs/upstream-controls.csv',
                    'docs/site/assets/application-icon.png', 'docs/site/assets/application-favicon.png',
                    'Sources/TurtleGitMac/Resources/TurtleGitHelp.help/Contents/Info.plist',
                    'Sources/TurtleGitMac/Resources/Localizable.xcstrings',
                    'Configuration/MetafileRuntime.json', 'scripts/test-native-reference-batch.py',
                    'LICENSE', 'NOTICE', 'AUTHORS.md', 'Licenses/Git.txt', '.github/workflows/macos.yml']
        for path in critical:
            with self.subTest(path=path):
                self.assertFalse(any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns))
        for path in ['README.md', 'docs/TESTING.md', 'docs/qa/notes/review.md',
                     'docs/qa/signed-consolidation-build49-2026-11-01.json',
                     'docs/qa/hosted-find-handoff-recovery-2026-11-01.json',
                     'docs/site/index.html', 'docs/site/style.css', 'docs/site/manual/search.js',
                     'docs/site/assets/mac-commit-classic-light-2026-10-31.png']:
            with self.subTest(path=path):
                self.assertTrue(any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns))
    def testBaselineCannotBeRewrittenToPermitHeaderDrift(self):
        for change in ['pull-request-filter', 'name', 'concurrency', 'new-event']:
            value = copy.deepcopy(self.workflow); inventory = copy.deepcopy(self.inventory)
            header = inventory['workflowHeader']
            if change == 'pull-request-filter':
                value['true']['pull_request'] = header['true']['pull_request'] = {'paths-ignore': ['docs/**']}
            if change == 'name': value['name'] = header['name'] = 'Renamed workflow'
            if change == 'concurrency':
                value['concurrency']['cancel-in-progress'] = header['concurrency']['cancel-in-progress'] = True
            if change == 'new-event': value['true']['workflow_dispatch'] = header['true']['workflow_dispatch'] = None
            with self.subTest(change=change), self.assertRaises(AssertionError): self.verify(value, inventory)
    def testReadmePushStillRequestsDocumentationChecks(self):
        pages = ci.yaml_document((ci.WORKFLOW.parent / 'pages.yml').read_text())
        push = pages['true']['push']
        self.assertEqual(push['branches'], ['main'])
        self.assertIn('README.md', push['paths']); self.assertIn('docs/**', push['paths'])
        commands = [step.get('run') for step in pages['jobs']['build']['steps']]
        for required in ['python3 scripts/build-help.py --check', 'python3 scripts/build-site.py',
                         'python3 scripts/test-site-docs.py', 'node scripts/test-site-search.cjs']:
            self.assertIn(required, commands)
    def testUtilityStartupCannotBeLostMovedOrChanged(self):
        for mutation in ['missing', 'duplicate', 'late', 'command', 'lane']:
            value = copy.deepcopy(self.workflow); steps = value['jobs']['validation']['steps']
            index = next(i for i, step in enumerate(steps) if step.get('name') == ci.UTILITY_STARTUP['name'])
            if mutation == 'missing': steps.pop(index)
            if mutation == 'duplicate': steps.insert(index + 1, copy.deepcopy(steps[index]))
            if mutation == 'late': steps.append(steps.pop(index))
            if mutation == 'command': steps[index]['run'] = 'true'
            if mutation == 'lane': steps[index]['if'] = "matrix.lane == 'editors'"
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError): self.verify(value)
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
    def testStatisticsFailureEvidenceHasExactOwnerAndPlacement(self):
        steps = self.workflow['jobs']['validation']['steps']
        indexes = [i for i, step in enumerate(steps)
                   if step.get('name') == ci.STATISTICS_FAILURE_EVIDENCE['name']]
        self.assertEqual(len(indexes), 1)
        index = indexes[0]
        self.assertEqual(steps[index], ci.STATISTICS_FAILURE_EVIDENCE)
        self.assertEqual(steps[index - 1]['name'], ci.STATISTICS_EXPORT_CONSUMER)
        self.verify()
    def testStatisticsFailureEvidenceMissingDuplicateMovedAndRenamedRefused(self):
        for mutation in ['missing', 'duplicate', 'before-producer', 'late', 'renamed']:
            value = copy.deepcopy(self.workflow); steps = value['jobs']['validation']['steps']
            index = next(i for i, step in enumerate(steps)
                         if step.get('name') == ci.STATISTICS_FAILURE_EVIDENCE['name'])
            if mutation == 'missing': steps.pop(index)
            if mutation == 'duplicate': steps.insert(index + 1, copy.deepcopy(steps[index]))
            if mutation == 'before-producer': steps.insert(index - 1, steps.pop(index))
            if mutation == 'late': steps.append(steps.pop(index))
            if mutation == 'renamed': steps[index]['name'] = 'Uninventoried Statistics artifact'
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError): self.verify(value)
    def testStatisticsEvidenceCannotRunForSuccessOrAnotherLane(self):
        for condition in ["matrix.lane == 'images-documents'", '${{ failure() }}', 'always()',
                          "${{ failure() && matrix.lane == 'commit-repository' }}",
                          "${{ success() && matrix.lane == 'images-documents' }}",
                          "${{ failure() || matrix.lane == 'images-documents' }}"]:
            value = copy.deepcopy(self.workflow)
            step = next(s for s in value['jobs']['validation']['steps']
                        if s.get('name') == ci.STATISTICS_FAILURE_EVIDENCE['name'])
            step['if'] = condition
            with self.subTest(condition=condition), self.assertRaises(AssertionError): self.verify(value)
    def testStatisticsEvidenceActionPathsRetentionAndEnvironmentCannotDrift(self):
        mutations = {
            'action-version': lambda s: s.update(uses='actions/upload-artifact@v3'),
            'another-action': lambda s: s.update(uses='another/upload@v4'),
            'artifact-name': lambda s: s['with'].update(name='statistics-export-failure'),
            'broad-path': lambda s: s['with'].update(path='build/**\n'),
            'extra-path': lambda s: s['with'].update(path=s['with']['path']+'**\n'),
            'missing-path': lambda s: s['with'].update(path=s['with']['path'].splitlines()[0]+'\n'),
            'missing-file-policy': lambda s: s['with'].update({'if-no-files-found': 'error'}),
            'retention': lambda s: s['with'].update({'retention-days': 90}),
            'missing-retention': lambda s: s['with'].pop('retention-days'),
            'extra-upload-setting': lambda s: s['with'].update({'include-hidden-files': True}),
            'extra-command': lambda s: s.update(run='true'),
            'extra-environment': lambda s: s.update(env={'UNREVIEWED': 'value'}),
        }
        for name, mutate in mutations.items():
            value = copy.deepcopy(self.workflow)
            step = next(s for s in value['jobs']['validation']['steps']
                        if s.get('name') == ci.STATISTICS_FAILURE_EVIDENCE['name'])
            mutate(step)
            with self.subTest(mutation=name), self.assertRaises(AssertionError): self.verify(value)
    def testStatisticsDiagnosticAdditionCannotHideProducerChanges(self):
        for field, replacement in [('run', 'true'), ('if', "matrix.lane == 'distribution'"),
                                   ('env', {'UNREVIEWED': 'value'})]:
            value = copy.deepcopy(self.workflow)
            step = next(s for s in value['jobs']['validation']['steps']
                        if s.get('name') == ci.STATISTICS_EXPORT_CONSUMER)
            step[field] = replacement
            with self.subTest(field=field), self.assertRaises(AssertionError): self.verify(value)
    def testPaneHeaderEvidenceRequiresItsFailedReadyOwnerAndExactPlacement(self):
        name=ci.PANE_HEADER_FAILURE_EVIDENCE['name']
        steps=self.workflow['jobs']['validation']['steps']
        index=next(i for i,step in enumerate(steps) if step.get('name')==name)
        self.assertEqual(steps[index],ci.PANE_HEADER_FAILURE_EVIDENCE)
        self.assertEqual(steps[index-1]['name'],ci.PANE_HEADER_CONSUMER)
        self.assertEqual(steps[index-1]['id'],'pane_headers')
        self.assertTrue(self.eligible(name,'editors',{'pane_headers':'failure'}))
        for lane,outcomes,cancelled in [
            ('core',{'pane_headers':'failure'},False),
            ('editors',{'pane_headers':'success'},False),
            ('editors',{'pane_headers':'skipped'},False),
            ('editors',{'native_ready':'failure','pane_headers':'failure'},False),
            ('editors',{'pane_headers':'failure'},True),
        ]:
            with self.subTest(lane=lane,outcomes=outcomes,cancelled=cancelled):
                self.assertFalse(self.eligible(name,lane,outcomes,cancelled))
        self.verify()
    def testPaneHeaderEvidenceCannotBroadenOrHideConsumerChanges(self):
        for mutation in ['missing','duplicate','before-owner','broad-path','extra-path',
                         'always','retention','hidden-files','consumer-command','consumer-id','consumer-guard']:
            value=copy.deepcopy(self.workflow);steps=value['jobs']['validation']['steps']
            index=next(i for i,step in enumerate(steps) if step.get('name')==ci.PANE_HEADER_FAILURE_EVIDENCE['name'])
            step=steps[index]
            owner=next(s for s in steps if s.get('name')==ci.PANE_HEADER_CONSUMER)
            if mutation=='missing':steps.pop(index)
            if mutation=='duplicate':steps.insert(index+1,copy.deepcopy(step))
            if mutation=='before-owner':steps.insert(index-1,steps.pop(index))
            if mutation=='broad-path':step['with']['path']='build/**'
            if mutation=='extra-path':step['with']['path']+='\n**'
            if mutation=='always':step['if']='always()'
            if mutation=='retention':step['with']['retention-days']=90
            if mutation=='hidden-files':step['with']['include-hidden-files']=True
            if mutation=='consumer-command':owner['run']='true'
            if mutation=='consumer-id':owner['id']='other'
            if mutation=='consumer-guard':owner['if']='always()'
            with self.subTest(mutation=mutation),self.assertRaises(AssertionError):self.verify(value)
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
