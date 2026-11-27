#!/usr/bin/env python3
"""Offline runner contracts: one compile, complete Add cohorts, private ownership."""
import contextlib
import io
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parent.parent
DRIVER=ROOT/'scripts/test-rebase-source.py'
COHORTS=['preparation','reached','no-commit-recovery','no-commit-split']


class RebaseSourceContracts(unittest.TestCase):
    def run_driver(self,arguments,fail=None):
        builds,calls=[],[]
        def build(root,sources,folder):
            builds.append([path.name for path in sources])
            return folder/'offline-receiver'
        def receive(command,**kwargs):
            env=kwargs['env'];fixture=Path(command[1]);cohort=env.get('TURTLEGIT_REBASE_ADD_COHORT')
            context=fixture.parent
            self.assertEqual(fixture.name,'repository')
            self.assertTrue(fixture.is_dir())
            for key in ['HOME','CFFIXED_USER_HOME','XDG_CONFIG_HOME','TMPDIR']:
                private=Path(env[key]);self.assertEqual(private.parent,context)
                self.assertEqual(private.stat().st_mode&0o777,0o700)
                self.assertNotEqual(private,fixture)
            self.assertTrue(env['TMPDIR'].endswith('/'))
            self.assertEqual(env['GIT_CONFIG_GLOBAL'],'/dev/null')
            self.assertEqual(env['GIT_CONFIG_NOSYSTEM'],'1')
            self.assertEqual(env['GIT_CONFIG_COUNT'],'0')
            self.assertTrue(kwargs['capture_output'] and kwargs['text'])
            # run_receiver's existing default remains 300s; no cohort inflation.
            self.assertNotIn('timeout',kwargs)
            calls.append((command[4],command[2],cohort,str(context),str(kwargs['timeout_sample'])))
            if fail:raise fail
            stdout='PASS: Rebase source family case completed\n'
            if cohort:stdout+='PASS: Rebase Add cohort '+cohort+'\n'
            return subprocess.CompletedProcess(command,0,stdout,'')
        native=types.ModuleType('native_receiver');native.build_receiver=build;native.run_receiver=receive
        with patch.dict(sys.modules,{'native_receiver':native}),patch.object(sys,'argv',[str(DRIVER)]+arguments),contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path(str(DRIVER),run_name='__main__')
        return builds,calls

    def test_add_is_complete_ordered_both_engines_with_one_full_compile(self):
        builds,calls=self.run_driver(['--only','add','--git','/fake/system','--git','/fake/bundled'])
        self.assertEqual(len(builds),1)
        self.assertEqual(len(builds[0]),7) # All six original fixtures and dispatch.
        self.assertIn('rebase-structural-no-commit-native-2026-10-26.swift',builds[0])
        self.assertIn('rebase-replay-progress-native-2026-10-14.swift',builds[0])
        self.assertEqual([(case,git,cohort) for case,git,cohort,_,_ in calls],
                         [('add',git,cohort) for git in ['/fake/system','/fake/bundled'] for cohort in COHORTS])
        self.assertEqual(len({row[3] for row in calls}),8)
        self.assertEqual(len({row[4] for row in calls}),8)

    def test_default_retains_all_original_cases_and_add_cohorts(self):
        builds,calls=self.run_driver(['--git','/fake/system','--git','/fake/bundled'])
        self.assertEqual(len(builds),1)
        expected=[]
        for case in ['structural-group','source','references','controls','add','replay']:
            for git in ['/fake/system','/fake/bundled']:
                expected.extend((case,git,cohort) for cohort in (COHORTS if case=='add' else [None]))
        self.assertEqual([(case,git,cohort) for case,git,cohort,_,_ in calls],expected)

    def test_non_add_case_never_inherits_add_cohort(self):
        with patch.dict('os.environ',{'TURTLEGIT_REBASE_ADD_COHORT':'no-commit-split'}):
            _,calls=self.run_driver(['--only','source'])
        self.assertEqual([row[:3] for row in calls],[('source','/usr/bin/git',None)])

    def test_timeout_stays_fail_fast_with_cohort_failure_evidence(self):
        failure=subprocess.TimeoutExpired(['offline-receiver'],300,output='full native phases',stderr='native diagnostic')
        original=tempfile.mkdtemp
        with tempfile.TemporaryDirectory(prefix='rebase-offline-evidence-') as temporary:
            evidence=Path(temporary)/'evidence'
            def allocate(*args,**kwargs):
                if kwargs.get('prefix','').startswith('rebase-source-add-failed-'):
                    evidence.mkdir();return str(evidence)
                return original(*args,**kwargs)
            with patch.object(tempfile,'mkdtemp',side_effect=allocate),self.assertRaises(subprocess.TimeoutExpired) as caught:
                self.run_driver(['--only','add','--git','/fake/system','--git','/fake/bundled'],fail=failure)
            self.assertIs(caught.exception,failure)
            receipt=json.loads((evidence/'failure.json').read_text())
            self.assertEqual((receipt['case'],receipt['cohort'],receipt['git']),('add','preparation','/fake/system'))
            self.assertEqual(receipt['receiver_timeout_seconds'],300)
            self.assertEqual((receipt['native_wait_iterations'],receipt['native_wait_sleep_seconds']),(2000,.01))
            self.assertEqual((evidence/'stdout.log').read_text(),'full native phases')
            self.assertEqual((evidence/'stderr.log').read_text(),'native diagnostic')
            self.assertTrue((evidence/'context/repository').is_dir())

    def test_standalone_cohorts_preserve_all_original_function_calls_and_cleanup(self):
        source=(ROOT/'docs/qa/rebase-add-preparation-native-2026-10-16.swift').read_text()
        dispatch=source[source.index('@MainActor static func verify()'):source.index('@MainActor static func verifyPreparation()')]
        self.assertIn('requested.map({[$0]}) ?? cohorts',dispatch)
        for function in ['verifyPreparation','reachedOrdering','repeatedReachedSkip','reachedOwnership','noCommitSquashRecovery','noCommitSquashSplit']:
            self.assertEqual(dispatch.count('try await '+function+'()'),1,function)
        self.assertIn('cleanupFailures.isEmpty',dispatch)
        self.assertIn('owners.isEmpty',dispatch)
        self.assertIn('CommitWindowModel.activeCommitPreflights==0',dispatch)
        self.assertIn('preparationOwners.allSatisfy',source)
        self.assertIn('sheets.allSatisfy',source)
        self.assertIn('context cleanup',source)


if __name__=='__main__':unittest.main()
