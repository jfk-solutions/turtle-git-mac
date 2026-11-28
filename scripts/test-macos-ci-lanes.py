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
    def testRebaseTimeoutStackCannotBeDroppedOrReplaceFailureReports(self):
        paths=['build/qa/ci-step-failures/middle/',
               'build/qa/rebase-source-*-timeout.sample.txt',
               'build/qa/rebase-source-add-failed-*/stdout.log',
               'build/qa/rebase-source-add-failed-*/stderr.log',
               'build/qa/rebase-source-add-failed-*/failure.json']
        step=next(s for s in self.workflow['jobs']['validation']['steps']
                  if s.get('name')=='Upload redacted CI failures middle')
        self.assertEqual(step['with']['path'].splitlines(),paths)
        for removed in paths:
            value=copy.deepcopy(self.workflow)
            step=next(s for s in value['jobs']['validation']['steps']
                      if s.get('name')=='Upload redacted CI failures middle')
            step['with']['path']=step['with']['path'].replace(removed+'\n','')
            with self.subTest(removed=removed),self.assertRaises(AssertionError):self.verify(value)
    def testNativeRunnerContractsKeepAllFourExactCommandsAndCoreAdmission(self):
        steps=self.workflow['jobs']['validation']['steps']
        index=next(i for i,step in enumerate(steps) if step.get('name')==ci.NATIVE_RUNNER_CONTRACT_NAME)
        self.assertEqual(steps[index], {'name':ci.NATIVE_RUNNER_CONTRACT_NAME, 'if':"matrix.lane == 'core'",
            'run':"python3 scripts/test-native-reference-groups-contracts.py\npython3 scripts/test-native-reference-batch-contracts.py\npython3 scripts/test-switch-reset-bisect-workflows-contracts.py\npython3 scripts/test-cherry-pick-native-contracts.py\n"})
        self.assertEqual(steps[index-1]['name'],'Pinned native translation labels')
        self.assertEqual(steps[index+1]['name'],'Native receiver cache and process ownership contracts')
        original=next(record for record in self.inventory['steps'] if record['id']=='original-004')
        self.assertEqual(original['name'],'Native reference group coverage contracts')
        self.assertEqual(original['lane'],'core')
        self.assertEqual(self.originals[4]['run'],'python3 scripts/test-native-reference-groups-contracts.py')
        self.verify()

    def testNativeRunnerContractsRejectDroppedChangedReorderedOrWeakenedCoverage(self):
        commands=['python3 scripts/test-native-reference-groups-contracts.py',
                  'python3 scripts/test-native-reference-batch-contracts.py',
                  'python3 scripts/test-switch-reset-bisect-workflows-contracts.py',
                  'python3 scripts/test-cherry-pick-native-contracts.py']
        for command in commands:
            for mutation in ['drop-command','replace-command','duplicate-command']:
                value=copy.deepcopy(self.workflow)
                step=next(step for step in value['jobs']['validation']['steps'] if step.get('name')==ci.NATIVE_RUNNER_CONTRACT_NAME)
                replacement='' if mutation=='drop-command' else ('true\n' if mutation=='replace-command' else command+'\n'+command+'\n')
                step['run']=step['run'].replace(command+'\n',replacement)
                with self.subTest(command=command,mutation=mutation),self.assertRaises(AssertionError):self.verify(value)
        for mutation in ['old-name','reorder','missing-step','duplicate-step','moved-step','wrong-lane','ready-gate','implicit-success','continue','extra-env']:
            value=copy.deepcopy(self.workflow);steps=value['jobs']['validation']['steps']
            index=next(i for i,step in enumerate(steps) if step.get('name')==ci.NATIVE_RUNNER_CONTRACT_NAME);step=steps[index]
            if mutation=='old-name':step['name']=ci.NATIVE_RUNNER_CONTRACT_ORIGINAL_NAME
            if mutation=='reorder':step['run']='\n'.join(reversed(commands))+'\n'
            if mutation=='missing-step':steps.pop(index)
            if mutation=='duplicate-step':steps.insert(index+1,copy.deepcopy(step))
            if mutation=='moved-step':steps.insert(index+1,steps.pop(index))
            if mutation=='wrong-lane':step['if']="matrix.lane == 'editors'"
            if mutation=='ready-gate':step['if']="matrix.lane == 'core' && steps.native_ready.outcome == 'success'"
            if mutation=='implicit-success':step['if']="success() && matrix.lane == 'core'"
            if mutation=='continue':step['continue-on-error']=True
            if mutation=='extra-env':step['env']={'UNREVIEWED':'value'}
            with self.subTest(mutation=mutation),self.assertRaises(AssertionError):self.verify(value)

    def testEditorReloadCannotReplaceOrDropViewportCoverage(self):
        for mutation in ['omit-reload', 'omit-viewport', 'omit-bundled', 'drop-ready']:
            with self.subTest(mutation=mutation):
                value = copy.deepcopy(self.workflow)
                step = next(s for s in value['jobs']['validation']['steps']
                            if s.get('name') == ci.EDITOR_VIEWPORT_NAME)
                if mutation == 'omit-reload': step['run'] = ci.EDITOR_VIEWPORT_ORIGINAL_RUN
                elif mutation == 'omit-viewport': step['run'] = step['run'].splitlines()[1] + '\n'
                elif mutation == 'omit-bundled': step['run'] = step['run'].replace(' --git build/git-runtime/Git/bin/git', '')
                else: step['if'] = step['if'].replace("steps.native_ready.outcome == 'success' && ", '')
                with self.assertRaises(Exception): self.verify(value)
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
    def testSSHConfigurationAccessHasReadyOwnerCancellationAndExactNeighbors(self):
        steps = self.workflow['jobs']['validation']['steps']
        index = next(i for i, step in enumerate(steps) if step.get('name') == ci.SSH_CONFIGURATION_ACCESS['name'])
        self.assertEqual(steps[index], ci.SSH_CONFIGURATION_ACCESS)
        self.assertEqual(steps[index - 1]['name'], ci.SSH_CONFIGURATION_ACCESS_ANCHOR)
        self.assertEqual(steps[index + 1]['name'], ci.SSH_CONFIGURATION_ACCESS_FOLLOWING)
        self.assertTrue(self.eligible(ci.SSH_CONFIGURATION_ACCESS['name'], 'settings-finder', {'earlier_native': 'failure'}))
        for lane in ci.LANES:
            with self.subTest(lane=lane):
                self.assertEqual(self.eligible(ci.SSH_CONFIGURATION_ACCESS['name'], lane), lane == 'settings-finder')
        for outcome in ['failure', 'skipped', 'cancelled', '']:
            with self.subTest(outcome=outcome):
                self.assertFalse(self.eligible(ci.SSH_CONFIGURATION_ACCESS['name'], 'settings-finder', {'native_ready': outcome}))
        self.assertFalse(self.eligible(ci.SSH_CONFIGURATION_ACCESS['name'], 'settings-finder', cancelled=True))
        self.verify()

    def testSSHConfigurationAccessCannotDriftOrExcuseOriginalChanges(self):
        mutations = ['missing', 'duplicate', 'before-anchor', 'after-neighbor', 'wrong-lane',
                     'wrong-command', 'drop-ready', 'implicit-success', 'always', 'drop-cancel',
                     'environment', 'continue-on-error', 'missing-anchor', 'anchor-command',
                     'missing-neighbor', 'neighbor-command', 'unmapped-adjacent-step']
        for mutation in mutations:
            value = copy.deepcopy(self.workflow); steps = value['jobs']['validation']['steps']
            index = next(i for i, step in enumerate(steps) if step.get('name') == ci.SSH_CONFIGURATION_ACCESS['name'])
            step = steps[index]
            anchor = next(s for s in steps if s.get('name') == ci.SSH_CONFIGURATION_ACCESS_ANCHOR)
            neighbor = next(s for s in steps if s.get('name') == ci.SSH_CONFIGURATION_ACCESS_FOLLOWING)
            if mutation == 'missing': steps.pop(index)
            if mutation == 'duplicate': steps.insert(index + 1, copy.deepcopy(step))
            if mutation == 'before-anchor': steps.insert(index - 1, steps.pop(index))
            if mutation == 'after-neighbor': steps.insert(index + 1, steps.pop(index))
            if mutation == 'wrong-lane': step['if'] = step['if'].replace('settings-finder', 'editors')
            if mutation == 'wrong-command': step['run'] = 'true'
            if mutation == 'drop-ready': step['if'] = step['if'].replace("steps.native_ready.outcome == 'success' && ", '')
            if mutation == 'implicit-success': step['if'] = "matrix.lane == 'settings-finder'"
            if mutation == 'always': step['if'] = step['if'].replace('!cancelled()', 'always()')
            if mutation == 'drop-cancel': step['if'] = step['if'].replace('!cancelled()', 'true')
            if mutation == 'environment': step['env'] = {'SKIP_ASSERTIONS': '1'}
            if mutation == 'continue-on-error': step['continue-on-error'] = True
            if mutation == 'missing-anchor': steps.remove(anchor)
            if mutation == 'anchor-command': anchor['run'] = 'true'
            if mutation == 'missing-neighbor': steps.remove(neighbor)
            if mutation == 'neighbor-command': neighbor['run'] = 'true'
            if mutation == 'unmapped-adjacent-step': steps.insert(index + 1, {'name': 'Unreviewed SSH check', 'run': 'true'})
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError):
                self.verify(value)

    def testExactNameRevertHasReadyOwnerAndExactPlacement(self):
        steps = self.workflow['jobs']['validation']['steps']
        index = next(i for i, step in enumerate(steps) if step.get('name') == ci.REVERT_EXACT['name'])
        self.assertEqual(steps[index], ci.REVERT_EXACT)
        self.assertEqual(steps[index - 1]['name'], ci.REVERT_EXACT_ANCHOR)
        self.assertTrue(self.eligible(ci.REVERT_EXACT['name'], 'commit-repository', {'earlier_native': 'failure'}))
        for lane in ci.LANES:
            with self.subTest(lane=lane):
                self.assertEqual(self.eligible(ci.REVERT_EXACT['name'], lane), lane == 'commit-repository')
        for outcome in ['failure', 'skipped', 'cancelled', '']:
            with self.subTest(outcome=outcome):
                self.assertFalse(self.eligible(ci.REVERT_EXACT['name'], 'commit-repository', {'native_ready': outcome}))
        self.assertFalse(self.eligible(ci.REVERT_EXACT['name'], 'commit-repository', cancelled=True))

    def testExactNameRevertAdditionCannotDriftOrHideOriginalChanges(self):
        mutations = ['missing', 'duplicate', 'before-anchor', 'late', 'wrong-lane',
                     'wrong-command', 'omit-bundled-git', 'broaden-cases', 'drop-ready',
                     'implicit-success', 'always', 'environment', 'missing-anchor', 'anchor-command']
        for mutation in mutations:
            value = copy.deepcopy(self.workflow); steps = value['jobs']['validation']['steps']
            index = next(i for i, step in enumerate(steps) if step.get('name') == ci.REVERT_EXACT['name'])
            step = steps[index]
            owner = next(s for s in steps if s.get('name') == ci.REVERT_EXACT_ANCHOR)
            if mutation == 'missing': steps.pop(index)
            if mutation == 'duplicate': steps.insert(index + 1, copy.deepcopy(step))
            if mutation == 'before-anchor': steps.insert(index - 1, steps.pop(index))
            if mutation == 'late': steps.append(steps.pop(index))
            if mutation == 'wrong-lane': step['if'] = step['if'].replace('commit-repository', 'editors')
            if mutation == 'wrong-command': step['run'] = 'true'
            if mutation == 'omit-bundled-git': step['run'] = step['run'].replace(' --git "$PWD/build/git-runtime/Git/bin/git"', '')
            if mutation == 'broaden-cases': step['run'] = step['run'].replace(' --only revert-exact', '')
            if mutation == 'drop-ready': step['if'] = step['if'].replace("steps.native_ready.outcome == 'success' && ", '')
            if mutation == 'implicit-success': step['if'] = "matrix.lane == 'commit-repository'"
            if mutation == 'always': step['if'] = step['if'].replace('!cancelled()', 'always()')
            if mutation == 'environment': step['env'] = {'SKIP_ASSERTIONS': '1'}
            if mutation == 'missing-anchor': steps.remove(owner)
            if mutation == 'anchor-command': owner['run'] = 'true'
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
        self.assertEqual(steps[setup_index - 2]['name'], ci.APP_BUILD_NAME)
        self.assertEqual(steps[setup_index - 1], ci.APP_BUILD_EVIDENCE)
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
    def testAppBuildEvidencePreservesOriginalCommandAndFailureExit(self):
        steps=self.workflow['jobs']['validation']['steps']
        index=next(i for i,step in enumerate(steps) if step.get('name')==ci.APP_BUILD_NAME)
        build=steps[index]
        self.assertEqual(build,{'name':ci.APP_BUILD_NAME,'id':'app_build','run':ci.APP_BUILD_RUN})
        self.assertEqual(build['run'].count(ci.APP_BUILD_ORIGINAL_RUN),1)
        self.assertIn('set -o pipefail\n',build['run'])
        self.assertIn('2>&1 | tee build/qa/app-build.log\n',build['run'])
        self.assertIn('xcodebuild -version\n',build['run'])
        self.assertIn('xcrun swift --version\n',build['run'])
        self.assertEqual(steps[index+1],ci.APP_BUILD_EVIDENCE)
        self.assertEqual(steps[index+2],ci.EDITOR_SETUP)
        # The actual condition has no lane gate: every failed app producer owns
        # its own small log; successful/skipped/cancelled producers upload none.
        expression=ci.APP_BUILD_EVIDENCE['if'][4:-3]
        for cancelled in [False,True]:
            for outcome in ['success','failure','skipped','cancelled','']:
                actual=expression.replace('!cancelled()',repr(not cancelled)).replace('steps.app_build.outcome',repr(outcome)).replace('&&',' and ')
                self.assertEqual(eval(actual,{'__builtins__':{}}),not cancelled and outcome=='failure')
        self.verify()

    def testAppBuildDiagnosticCommandAndArtifactDriftFailClosed(self):
        for mutation in ['no-id','conditional','no-pipefail','no-stderr','no-tee','no-version','swallow-exit','flags']:
            value=copy.deepcopy(self.workflow)
            step=next(s for s in value['jobs']['validation']['steps'] if s.get('name')==ci.APP_BUILD_NAME)
            if mutation=='no-id':step.pop('id')
            if mutation=='conditional':step['if']="matrix.lane == 'core'"
            if mutation=='no-pipefail':step['run']=step['run'].replace('set -o pipefail\n','')
            if mutation=='no-stderr':step['run']=step['run'].replace(' 2>&1 | tee',' | tee')
            if mutation=='no-tee':step['run']=step['run'].replace(' | tee build/qa/app-build.log','')
            if mutation=='no-version':step['run']=step['run'].replace('  xcrun swift --version\n','')
            if mutation=='swallow-exit':step['run']+='true\n'
            if mutation=='flags':step['run']=step['run'].replace('CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_ALLOWED=YES')
            with self.subTest(build=mutation),self.assertRaises(AssertionError):self.verify(value)
        for mutation in ['missing','duplicate','moved','cancel','failure-owner','wrong-id','lane-only','artifact-name','broad-path','missing-file-policy','retention','action','continue']:
            value=copy.deepcopy(self.workflow);steps=value['jobs']['validation']['steps']
            index=next(i for i,step in enumerate(steps) if step.get('name')==ci.APP_BUILD_EVIDENCE['name']);step=steps[index]
            if mutation=='missing':steps.pop(index)
            if mutation=='duplicate':steps.insert(index+1,copy.deepcopy(step))
            if mutation=='moved':steps.insert(index+1,steps.pop(index))
            if mutation=='cancel':step['if']=step['if'].replace('!cancelled() && ','')
            if mutation=='failure-owner':step['if']="${{ failure() }}"
            if mutation=='wrong-id':step['if']=step['if'].replace('app_build','native_ready')
            if mutation=='lane-only':step['if']="${{ !cancelled() && matrix.lane == 'core' }}"
            if mutation=='artifact-name':step['with']['name']='app-build'
            if mutation=='broad-path':step['with']['path']='build/**'
            if mutation=='missing-file-policy':step['with']['if-no-files-found']='ignore'
            if mutation=='retention':step['with']['retention-days']=90
            if mutation=='action':step['uses']='actions/upload-artifact@v3'
            if mutation=='continue':step['continue-on-error']=True
            with self.subTest(artifact=mutation),self.assertRaises(AssertionError):self.verify(value)

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
    def testReviewedHistoryFamilyHasExactPlacementAndLaneReadiness(self):
        additions = [ci.HISTORY_CONTEXT, ci.HISTORY_CONTEXT_EVIDENCE,
                     ci.LOG_PRIMARY, ci.LOG_PRIMARY_EVIDENCE]
        steps = self.workflow['jobs']['validation']['steps']
        anchor = next(i for i, step in enumerate(steps)
                      if step.get('name') == ci.HISTORY_CONTEXT_ANCHOR)
        self.assertEqual(steps[anchor + 1:anchor + 5], additions)
        self.assertEqual(steps[anchor + 5]['name'], 'Native Log double-click preference receiver')
        for step in additions:
            name = step['name']
            with self.subTest(name=name):
                self.assertTrue(self.eligible(name, 'history-references', {'earlier_native': 'failure'}))
                for lane in ci.LANES:
                    if lane != 'history-references':
                        self.assertFalse(self.eligible(name, lane))
                self.assertFalse(self.eligible(name, 'history-references', cancelled=True))
                for outcome in ['failure', 'skipped', 'cancelled', '']:
                    self.assertFalse(self.eligible(name, 'history-references', {'native_ready': outcome}))
        # Diagnostics remain eligible after their owned test fails. They do not
        # mask that failure or depend on the other family's result.
        for step in [ci.HISTORY_CONTEXT_EVIDENCE, ci.LOG_PRIMARY_EVIDENCE]:
            self.assertTrue(self.eligible(step['name'], 'history-references',
                                          {'earlier_native': 'failure', 'history_context': 'failure',
                                           'log_primary': 'failure'}))
        self.assertNotIn('--only conflict-routing', ci.LOG_PRIMARY['run'])
        self.assertNotIn('--only conflict-commands', ci.LOG_PRIMARY['run'])
        self.assertNotIn('--only image-conflict', ci.LOG_PRIMARY['run'])
        self.verify()

    def testReviewedStatusConsumersHaveExactPlacementAndReadyOwners(self):
        steps=self.workflow['jobs']['validation']['steps']
        for anchor,additions,following in ci.STATUS_CONSUMER_ADDITIONS + ci.METAFILE_PATH_ADDITIONS:
            index=next(i for i,step in enumerate(steps) if step.get('name')==anchor)
            self.assertEqual(steps[index+1:index+1+len(additions)],list(additions))
            self.assertEqual(steps[index+1+len(additions)]['name'],following)
            for expected in additions:
                lane=next(value for value in ci.LANES if "matrix.lane == '"+value+"'" in expected['if'])
                with self.subTest(name=expected['name']):
                    self.assertTrue(self.eligible(expected['name'],lane,{'earlier_native':'failure'}))
                    self.assertFalse(self.eligible(expected['name'],lane,cancelled=True))
                    for other in ci.LANES:
                        if other!=lane:self.assertFalse(self.eligible(expected['name'],other))
                    for outcome in ['failure','skipped','cancelled','']:
                        self.assertFalse(self.eligible(expected['name'],lane,{'native_ready':outcome}))
        self.verify()

    def testReviewedStatusConsumersRejectUnknownMissingDuplicateMovedAndCommandDrift(self):
        names=[step['name'] for _,steps,_ in ci.STATUS_CONSUMER_ADDITIONS + ci.METAFILE_PATH_ADDITIONS for step in steps]
        mutations=['missing','duplicate','moved','renamed','wrong-lane','drop-ready','drop-cancel',
                   'implicit-success','always','command','omit-system','omit-bundled','scope',
                   'extra-command','extra-env','extra-id','continue-on-error','extra-action']
        for name in names:
            for mutation in mutations:
                value=copy.deepcopy(self.workflow);steps=value['jobs']['validation']['steps']
                index=next(i for i,step in enumerate(steps) if step.get('name')==name);step=steps[index]
                if mutation=='missing':steps.pop(index)
                if mutation=='duplicate':steps.insert(index+1,copy.deepcopy(step))
                if mutation=='moved':steps.insert(index-1,steps.pop(index))
                if mutation=='renamed':step['name']+=' changed'
                if mutation=='wrong-lane':step['if']=step['if'].replace("matrix.lane == '","matrix.lane == 'unreviewed-")
                if mutation=='drop-ready':step['if']=step['if'].replace("steps.native_ready.outcome == 'success' && ",'')
                if mutation=='drop-cancel':step['if']=step['if'].replace('!cancelled() && ','')
                if mutation=='implicit-success':step['if']="matrix.lane == 'core'"
                if mutation=='always':step['if']=step['if'].replace('!cancelled()','always()')
                if mutation=='command':step['run']='true'
                if mutation=='omit-system':step['run']=step['run'].replace('--git /usr/bin/git ','')
                if mutation=='omit-bundled':step['run']=step['run'].replace(' --git "$PWD/build/git-runtime/Git/bin/git"','')
                if mutation=='scope':step['run']+=' --only unrelated'
                if mutation=='extra-command':step['run']+='\ntrue'
                if mutation=='extra-env':step['env']={'UNREVIEWED':'value'}
                if mutation=='extra-id':step['id']='unreviewed'
                if mutation=='continue-on-error':step['continue-on-error']=True
                if mutation=='extra-action':step['uses']='actions/checkout@v4'
                with self.subTest(name=name,mutation=mutation),self.assertRaises(AssertionError):self.verify(value)
        value=copy.deepcopy(self.workflow)
        value['jobs']['validation']['steps'].insert(100,{'name':'Unknown new status consumer','run':'true'})
        with self.assertRaises(AssertionError):self.verify(value)

    def testReviewedStatusConsumerAnchorsAndOriginalNeighborsRemainImmutable(self):
        for anchor,_,following in ci.STATUS_CONSUMER_ADDITIONS + ci.METAFILE_PATH_ADDITIONS:
            for name in [anchor,following]:
                value=copy.deepcopy(self.workflow)
                step=next(step for step in value['jobs']['validation']['steps'] if step.get('name')==name)
                step['run']='true'
                with self.subTest(name=name),self.assertRaises(AssertionError):self.verify(value)

    def testNaturalWorkingStatusProjectionRetainsAllFiveCohortsAndBothGitEngines(self):
        steps=self.workflow['jobs']['validation']['steps']
        name=ci.WORKING_STATUS_PROJECTION['name']
        index=next(i for i,step in enumerate(steps) if step.get('name')==name)
        self.assertEqual(steps[index],ci.WORKING_STATUS_PROJECTION)
        self.assertEqual(steps[index-1]['name'],ci.STATUS_OPERANDS['name'])
        self.assertEqual(steps[index+1],ci.SCOPED_WORKING_READS)
        self.assertEqual(steps[index+2],ci.CHANGED_SCOPED_STATUS)
        self.assertEqual(steps[index+3]['name'],'Native Commit report rows, fonts and geometry ownership')
        self.assertTrue(self.eligible(name,'commit-repository',{'earlier_native':'failure'}))
        self.assertFalse(self.eligible(name,'commit-repository',cancelled=True))
        for cohort in ['commit','status','add','log','revert']:
            self.assertEqual(steps[index]['run'].count('--only '+cohort+' '),1)
            value=copy.deepcopy(self.workflow)
            value['jobs']['validation']['steps'][index]['run']=steps[index]['run'].replace('--only '+cohort+' ','')
            with self.subTest(missing=cohort),self.assertRaises(AssertionError):self.verify(value)
        for outcome in ['failure','skipped','cancelled','']:
            self.assertFalse(self.eligible(name,'commit-repository',{'native_ready':outcome}))
        for lane in ci.LANES:
            if lane!='commit-repository':self.assertFalse(self.eligible(name,lane))
        # The generic reviewed-status mutation matrix also covers this exact
        # addition's guard, command, duplicate, missing and neighbor contracts.

    def testScopedWorkingReadsRetainAllCohortsExactNeighborsAndReadyOwner(self):
        steps=self.workflow['jobs']['validation']['steps']
        name=ci.SCOPED_WORKING_READS['name']
        index=next(i for i,step in enumerate(steps) if step.get('name')==name)
        self.assertEqual(steps[index],ci.SCOPED_WORKING_READS)
        self.assertEqual(steps[index-1],ci.WORKING_STATUS_PROJECTION)
        self.assertEqual(steps[index+1],ci.CHANGED_SCOPED_STATUS)
        self.assertEqual(steps[index+2]['name'],'Native Commit report rows, fonts and geometry ownership')
        for cohort in ['add','revert','rescope-cancel','commit']:
            self.assertEqual(steps[index]['run'].count('--only '+cohort+' '),1)
            value=copy.deepcopy(self.workflow)
            value['jobs']['validation']['steps'][index]['run']=steps[index]['run'].replace('--only '+cohort+' ','')
            with self.subTest(missing=cohort),self.assertRaises(AssertionError):self.verify(value)
        self.assertTrue(self.eligible(name,'commit-repository',{'earlier_native':'failure'}))
        self.assertFalse(self.eligible(name,'commit-repository',cancelled=True))
        for outcome in ['failure','skipped','cancelled','']:
            self.assertFalse(self.eligible(name,'commit-repository',{'native_ready':outcome}))
        for lane in ci.LANES:
            if lane!='commit-repository':self.assertFalse(self.eligible(name,lane))
        # The full reviewed-status mutation matrix also exercises both Git
        # arguments, command drift, duplicate/missing/moved steps and guards.

    def testNewChangedAndClassicPathConsumersHaveExactCasesAndOwnedLanes(self):
        steps=self.workflow['jobs']['validation']['steps']
        cases=[
            (ci.CHANGED_SCOPED_STATUS,'commit-repository',['projection','retry','cancellation'],ci.SCOPED_WORKING_READS['name'],'Native Commit report rows, fonts and geometry ownership'),
            (ci.CLASSIC_METAFILE_PATHS,'images-documents',['consumers','ownership'],'Classic WMF and EMF Boolean raster consumers and conflict ownership','Classic EMF masked and transparent bitmap transfers'),
        ]
        for expected,lane,cohorts,before,after in cases:
            name=expected['name']
            index=next(i for i,step in enumerate(steps) if step.get('name')==name)
            self.assertEqual(steps[index],expected)
            self.assertEqual(steps[index-1]['name'],before)
            self.assertEqual(steps[index+1]['name'],after)
            for cohort in cohorts:
                self.assertEqual(steps[index]['run'].count('--only '+cohort+' '),1)
                value=copy.deepcopy(self.workflow)
                value['jobs']['validation']['steps'][index]['run']=steps[index]['run'].replace('--only '+cohort+' ','')
                with self.subTest(name=name,missing=cohort),self.assertRaises(AssertionError):self.verify(value)
            self.assertTrue(self.eligible(name,lane,{'earlier_native':'failure'}))
            self.assertFalse(self.eligible(name,lane,cancelled=True))
            for outcome in ['failure','skipped','cancelled','']:
                self.assertFalse(self.eligible(name,lane,{'native_ready':outcome}))
            for other in ci.LANES:
                if other!=lane:self.assertFalse(self.eligible(name,other))
        # Generic exact-consumer mutations include both families: missing/
        # duplicate/moved steps, wrong guards, both Git arguments and drift.

    def testBlameFocusRetainsOriginalCasesReadyOwnerAndExactNeighbors(self):
        steps=self.workflow['jobs']['validation']['steps']
        index=next(i for i,step in enumerate(steps) if step.get('name')==ci.BLAME_SOURCE_NAME)
        self.assertEqual(steps[index]['run'],ci.BLAME_SOURCE_FOCUS_RUN)
        self.assertEqual(steps[index-1]['name'],'Native symbolic-link Blame documents and incoming commands')
        self.assertEqual([step['name'] for step in steps[index+1:index+4]],
                         [ci.LOG_SELECTED['name'],ci.LOG_OPERANDS['name'],'Native Blame retained-byte encoding recovery and cancellation'])
        for case in ['commands','source-menu','focus']:self.assertIn('--only '+case+' ',steps[index]['run'])
        self.assertTrue(self.eligible(ci.BLAME_SOURCE_NAME,'history-references',{'earlier_native':'failure'}))
        self.assertFalse(self.eligible(ci.BLAME_SOURCE_NAME,'history-references',cancelled=True))
        for lane in ci.LANES:
            if lane!='history-references':self.assertFalse(self.eligible(ci.BLAME_SOURCE_NAME,lane))
        for outcome in ['failure','skipped','cancelled','']:
            self.assertFalse(self.eligible(ci.BLAME_SOURCE_NAME,'history-references',{'native_ready':outcome}))
        for mutation in ['drop-focus','drop-commands','drop-source-menu','scope','system','bundled','guard','lane','cancel','extra-env','duplicate','moved']:
            value=copy.deepcopy(self.workflow);changed=value['jobs']['validation']['steps'];step=changed[index]
            if mutation.startswith('drop-'):step['run']=step['run'].replace('--only '+mutation[5:]+' ','')
            if mutation=='scope':step['run']+=' --only unrelated'
            if mutation=='system':step['run']=step['run'].replace('--git /usr/bin/git ','')
            if mutation=='bundled':step['run']=step['run'].replace(' --git build/Build/Products/Debug/TurtleGitMac.app/Contents/Resources/TurtleGitRuntimes/Git/bin/git','')
            if mutation=='guard':step['if']=step['if'].replace("steps.native_ready.outcome == 'success' && ",'')
            if mutation=='lane':step['if']=step['if'].replace('history-references','editors')
            if mutation=='cancel':step['if']=step['if'].replace('!cancelled() && ','')
            if mutation=='extra-env':step['env']={'UNREVIEWED':'value'}
            if mutation=='duplicate':changed.insert(index+1,copy.deepcopy(step))
            if mutation=='moved':changed.insert(index-1,changed.pop(index))
            with self.subTest(mutation=mutation),self.assertRaises(AssertionError):self.verify(value)
        for name in ['Native symbolic-link Blame documents and incoming commands','Native Blame retained-byte encoding recovery and cancellation']:
            value=copy.deepcopy(self.workflow)
            step=next(step for step in value['jobs']['validation']['steps'] if step.get('name')==name);step['run']='true'
            with self.subTest(neighbor=name),self.assertRaises(AssertionError):self.verify(value)
        self.verify()
    def testReviewedHistoryAdditionsCannotDriftOrExemptOriginalNeighbors(self):
        names = [ci.HISTORY_CONTEXT['name'], ci.HISTORY_CONTEXT_EVIDENCE['name'],
                 ci.LOG_PRIMARY['name'], ci.LOG_PRIMARY_EVIDENCE['name']]
        for name in names:
            for mutation in ['missing', 'duplicate', 'reordered', 'renamed', 'wrong-lane',
                             'drop-ready', 'drop-cancel', 'implicit-success', 'always',
                             'continue-on-error', 'extra-env', 'extra-id']:
                value = copy.deepcopy(self.workflow); steps = value['jobs']['validation']['steps']
                index = next(i for i, step in enumerate(steps) if step.get('name') == name)
                step = steps[index]
                if mutation == 'missing': steps.pop(index)
                if mutation == 'duplicate': steps.insert(index + 1, copy.deepcopy(step))
                if mutation == 'reordered': steps.insert(index - 1, steps.pop(index))
                if mutation == 'renamed': step['name'] += ' changed'
                if mutation == 'wrong-lane': step['if'] = step['if'].replace('history-references', 'core')
                if mutation == 'drop-ready': step['if'] = step['if'].replace("steps.native_ready.outcome == 'success' && ", '')
                if mutation == 'drop-cancel': step['if'] = step['if'].replace('!cancelled() && ', '')
                if mutation == 'implicit-success': step['if'] = "matrix.lane == 'history-references'"
                if mutation == 'always': step['if'] = step['if'].replace('!cancelled()', 'always()')
                if mutation == 'continue-on-error': step['continue-on-error'] = True
                if mutation == 'extra-env': step['env'] = {'UNREVIEWED': 'value'}
                if mutation == 'extra-id': step['id'] = 'unreviewed'
                with self.subTest(name=name, mutation=mutation), self.assertRaises(AssertionError):
                    self.verify(value)
        for name in [ci.HISTORY_CONTEXT_ANCHOR, 'Native Log double-click preference receiver']:
            value = copy.deepcopy(self.workflow)
            next(s for s in value['jobs']['validation']['steps'] if s.get('name') == name)['run'] = 'true'
            with self.subTest(original_neighbor=name), self.assertRaises(AssertionError): self.verify(value)
    def testHistoryCommandsKeepExactCasesBothGitEnginesAndFailurePropagation(self):
        for name in [ci.HISTORY_CONTEXT['name'], ci.LOG_PRIMARY['name']]:
            for mutation in ['command', 'omit-system', 'omit-bundled', 'broaden-cases',
                             'pipefail', 'output', 'timeout', 'extra-command']:
                value = copy.deepcopy(self.workflow)
                step = next(s for s in value['jobs']['validation']['steps'] if s.get('name') == name)
                if mutation == 'command': step['run'] = 'true'
                if mutation == 'omit-system': step['run'] = step['run'].replace('--git /usr/bin/git ', '')
                if mutation == 'omit-bundled': step['run'] = step['run'].replace('--git build/git-runtime/Git/bin/git ', '')
                if mutation == 'broaden-cases': step['run'] = step['run'].replace('--only primary ', '') if name == ci.LOG_PRIMARY['name'] else step['run'].replace('--only browser-context ', '--only browser-files ')
                if mutation == 'pipefail': step['run'] = step['run'].replace('set -o pipefail\n', '')
                if mutation == 'output': step['run'] = step['run'].replace('2>&1 | tee', '2>&1 >')
                if mutation == 'timeout': step.pop('timeout-minutes')
                if mutation == 'extra-command': step['run'] += 'true\n'
                with self.subTest(name=name, mutation=mutation), self.assertRaises(AssertionError): self.verify(value)
    def testHistoryDiagnosticArtifactsKeepNarrowExactContracts(self):
        for name in [ci.HISTORY_CONTEXT_EVIDENCE['name'], ci.LOG_PRIMARY_EVIDENCE['name']]:
            for mutation in ['action', 'artifact-name', 'broad-path', 'extra-path', 'missing-path',
                             'retention', 'hidden-files', 'missing-file-policy', 'extra-command']:
                value = copy.deepcopy(self.workflow)
                step = next(s for s in value['jobs']['validation']['steps'] if s.get('name') == name)
                if mutation == 'action': step['uses'] = 'actions/upload-artifact@v3'
                if mutation == 'artifact-name': step['with']['name'] = 'unowned-diagnostics'
                if mutation == 'broad-path': step['with']['path'] = 'build/**\n'
                if mutation == 'extra-path': step['with']['path'] += '**\n'
                if mutation == 'missing-path': step['with']['path'] = step['with']['path'].splitlines()[0] + '\n'
                if mutation == 'retention': step['with']['retention-days'] = 90
                if mutation == 'hidden-files': step['with']['include-hidden-files'] = True
                if mutation == 'missing-file-policy': step['with']['if-no-files-found'] = 'ignore'
                if mutation == 'extra-command': step['run'] = 'true'
                with self.subTest(name=name, mutation=mutation), self.assertRaises(AssertionError): self.verify(value)
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
    def testFailureDiagnosticsHaveExactValidationEnvironmentAndCheckpointOwners(self):
        worker=self.workflow['jobs']['validation']
        self.assertEqual(worker['env'],ci.CI_STEP_LOG_ENV)
        for name in ['svn-runtime','build-and-test']:
            self.assertNotIn('BASH_ENV',self.workflow['jobs'][name].get('env',{}))
        steps=worker['steps']
        for checkpoint,anchor,following in ci.CI_FAILURE_CHECKPOINTS:
            expected=ci.failure_checkpoint_steps(checkpoint)
            index=next(i for i,step in enumerate(steps) if step.get('name')==anchor)+1
            self.assertEqual(steps[index:index+2],list(expected))
            if following is None:self.assertEqual(index+2,len(steps))
            else:self.assertEqual(steps[index+2]['name'],following)
            for ready in ['success','failure','skipped','cancelled','']:
                for cancelled in [False,True]:
                    for present in ['true','false','']:
                        for lane in ci.LANES:
                            for offset,step in enumerate(expected):
                                expression=step['if'][4:-3]
                                expression=expression.replace('!cancelled()',repr(not cancelled)).replace('steps.native_ready.outcome',repr(ready)).replace('steps.ci_failures_'+checkpoint+'.outputs.present',repr(present)).replace('matrix.lane',repr(lane)).replace('&&',' and ')
                                permitted=not cancelled and (checkpoint!='references' or lane=='editors') and (offset==0 or present=='true')
                                self.assertEqual(eval(expression,{'__builtins__':{}}),permitted)
            self.assertNotIn('build/ci-step-logs',expected[1]['with']['path'])
            self.assertEqual(expected[1]['with']['if-no-files-found'],'ignore')
        self.verify()

    def testReferenceGroupDiagnosticsCannotLoseEditorsScopeOrOriginalConsumers(self):
        expected=ci.failure_checkpoint_steps('references')
        for name in [step['name'] for step in expected]:
            for mutation in ['wrong-lane','drop-lane','unbounded-path','unrelated-owner']:
                value=copy.deepcopy(self.workflow)
                step=next(s for s in value['jobs']['validation']['steps'] if s.get('name')==name)
                if mutation=='wrong-lane':step['if']=step['if'].replace("'editors'", "'distribution'")
                if mutation=='drop-lane':step['if']=step['if'].replace(" && matrix.lane == 'editors'", '')
                if mutation=='unbounded-path':
                    if 'run' in step:step['run']+=' --logs build/qa'
                    else:step['with']['path']='build/qa/**'
                if mutation=='unrelated-owner':
                    if 'id' in step:step['id']='ci_failures_middle'
                    else:step['if']=step['if'].replace('ci_failures_references','ci_failures_middle')
                with self.subTest(name=name,mutation=mutation),self.assertRaises(AssertionError):self.verify(value)

    def testFinalDiagnosticsKeepExactGeneratedGraphPayloadsWithoutPrivateTrees(self):
        expected=['build/qa/ci-step-failures/final/']+[
            'build/qa/statistics-decode-'+family+'-*/'+name
            for family in ['family','authors','graph'] for name in ['failed-graph.emf','failure.json']]
        step=ci.failure_checkpoint_steps('final')[1]
        self.assertEqual(step['with']['path'].splitlines(),expected)
        for mutation in ['missing-payload','private-tree','broad-graph-root','unrelated-source']:
            value=copy.deepcopy(self.workflow)
            actual=next(s for s in value['jobs']['validation']['steps'] if s.get('name')==step['name'])
            if mutation=='missing-payload':actual['with']['path']='\n'.join(expected[:-1])+'\n'
            elif mutation=='private-tree':actual['with']['path']+='build/qa/statistics-decode-*/**\n'
            elif mutation=='broad-graph-root':actual['with']['path']='build/qa/**\n'
            else:actual['with']['path']+='Sources/**\n'
            with self.subTest(mutation=mutation),self.assertRaises(AssertionError):self.verify(value)

    def testFailureDiagnosticsRejectEnvironmentControlArtifactAndPlacementDrift(self):
        for mutation in ['missing','other-path','extra-env','root-env']:
            value=copy.deepcopy(self.workflow)
            worker=value['jobs']['validation']
            if mutation=='missing':worker.pop('env')
            if mutation=='other-path':worker['env']['BASH_ENV']='scripts/unreviewed-hook.sh'
            if mutation=='extra-env':worker['env']['UNREVIEWED']='value'
            if mutation=='root-env':value['env']=worker.pop('env')
            with self.subTest(environment=mutation),self.assertRaises(AssertionError):self.verify(value)
        for checkpoint,anchor,following in ci.CI_FAILURE_CHECKPOINTS:
            expected=ci.failure_checkpoint_steps(checkpoint)
            for offset in [0,1]:
                for mutation in ['missing','duplicate','moved','guard-ready','guard-cancel','implicit-success','always','extra-env','continue','identity','command-or-action','publish-raw','scope','retention-or-id','present-owner']:
                    value=copy.deepcopy(self.workflow)
                    steps=value['jobs']['validation']['steps']
                    index=next(i for i,step in enumerate(steps) if step.get('name')==expected[offset]['name'])
                    step=steps[index]
                    if mutation=='missing':steps.pop(index)
                    if mutation=='duplicate':steps.insert(index+1,copy.deepcopy(step))
                    if mutation=='moved':steps.insert(index-1,steps.pop(index))
                    if mutation=='guard-ready':step['if']=step['if'][:-3]+" && steps.native_ready.outcome == 'success' }}"
                    if mutation=='guard-cancel':step['if']=step['if'].replace('!cancelled()','true')
                    if mutation=='implicit-success':step['if']="steps.native_ready.outcome == 'success'"
                    if mutation=='always':step['if']=step['if'].replace('!cancelled()','always()')
                    if mutation=='extra-env':step['env']={'UNREVIEWED':'value'}
                    if mutation=='continue':step['continue-on-error']=True
                    if mutation=='identity':step['name']+=' changed'
                    if offset==0:
                        if mutation=='command-or-action':step['run']='true'
                        if mutation=='publish-raw':step['run']=step['run'].replace('build/qa/ci-step-failures/'+checkpoint,'build/ci-step-logs')
                        if mutation=='scope':step['run']=step['run'].replace('--checkpoint '+checkpoint,'--checkpoint unrelated')
                        if mutation=='retention-or-id':step['id']='unreviewed'
                        if mutation=='present-owner':step['run']+=' --logs unrelated'
                    else:
                        if mutation=='command-or-action':step['uses']='actions/upload-artifact@v3'
                        if mutation=='publish-raw':step['with']['path']='build/ci-step-logs/**'
                        if mutation=='scope':step['with']['name']='ci-failures'
                        if mutation=='retention-or-id':step['with']['retention-days']=90
                        if mutation=='present-owner':step['if']=step['if'].replace('ci_failures_'+checkpoint,'ci_failures_unrelated')
                    with self.subTest(checkpoint=checkpoint,offset=offset,mutation=mutation),self.assertRaises(AssertionError):self.verify(value)
            for name in [anchor]+([following] if following else []):
                value=copy.deepcopy(self.workflow)
                step=next(step for step in value['jobs']['validation']['steps'] if step.get('name')==name)
                step['run']='true'
                with self.subTest(checkpoint=checkpoint,neighbor=name),self.assertRaises(AssertionError):self.verify(value)

    def testEarlyCoreCILogContractHasExactCommandCancellationAndNeighbors(self):
        steps=self.workflow['jobs']['validation']['steps']
        index=next(i for i,step in enumerate(steps) if step.get('name')==ci.CI_STEP_LOG_CONTRACT['name'])
        self.assertEqual(steps[index],ci.CI_STEP_LOG_CONTRACT)
        self.assertEqual(steps[index-1]['name'],ci.CI_STEP_LOG_CONTRACT_ANCHOR)
        self.assertEqual(steps[index+1]['name'],ci.CI_STEP_LOG_CONTRACT_FOLLOWING)
        self.assertNotIn('native_ready',steps[index]['if'])
        self.assertTrue(self.eligible(ci.CI_STEP_LOG_CONTRACT['name'],'core',{'native_ready':'failure'}))
        self.assertFalse(self.eligible(ci.CI_STEP_LOG_CONTRACT['name'],'core',cancelled=True))
        for lane in ci.LANES:
            if lane!='core':self.assertFalse(self.eligible(ci.CI_STEP_LOG_CONTRACT['name'],lane))
        for mutation in ['missing','duplicate','moved','command','ready-gate','wrong-lane','no-cancel','always','continue','extra-env']:
            value=copy.deepcopy(self.workflow);changed=value['jobs']['validation']['steps'];step=changed[index]
            if mutation=='missing':changed.pop(index)
            if mutation=='duplicate':changed.insert(index+1,copy.deepcopy(step))
            if mutation=='moved':changed.insert(index-1,changed.pop(index))
            if mutation=='command':step['run']='true'
            if mutation=='reorder-commands':step['run']='\n'.join(reversed(commands))+'\n'
            if mutation=='ready-gate':step['if']=step['if'].replace("matrix.lane == 'core'","steps.native_ready.outcome == 'success'")
            if mutation=='wrong-lane':step['if']=step['if'].replace("'core'","'editors'")
            if mutation=='no-cancel':step['if']=step['if'].replace('!cancelled()','true')
            if mutation=='always':step['if']=step['if'].replace('!cancelled()','always()')
            if mutation=='continue':step['continue-on-error']=True
            if mutation=='extra-env':step['env']={'UNREVIEWED':'value'}
            with self.subTest(mutation=mutation),self.assertRaises(AssertionError):self.verify(value)
        self.verify()

    def testOriginalSVNProducerUnchangedExceptExplicitTimeout(self):
        # Its complete source is pinned in the baseline verification; here guard
        # the producer artifact required by every matrix worker as well.
        producer = self.workflow['jobs']['svn-runtime']
        upload = producer['steps'][-1]
        download = next(s for s in self.workflow['jobs']['validation']['steps'] if s.get('uses') == 'actions/download-artifact@v4')
        self.assertEqual(upload['with']['name'], download['with']['name'])
        self.assertEqual(upload['with']['path'], 'build/git-svn-runtime/GitSVN.tar.gz')

if __name__ == '__main__': unittest.main()
