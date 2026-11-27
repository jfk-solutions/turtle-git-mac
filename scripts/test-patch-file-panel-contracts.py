#!/usr/bin/env python3
"""Offline patch-family compiler partition, source closure and runtime contracts."""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('patch_panel_driver',ROOT/'scripts/test-patch-file-panel.py')
driver=importlib.util.module_from_spec(spec);spec.loader.exec_module(driver)
ORIGINAL_FIXTURES={
 'patch-special-recovery-native-2026-10-16.swift':'PatchSpecialRecoveryVerification',
 'patch-recovery-native-2026-10-16.swift':'PatchRecoveryVerification',
 'patch-file-panel-native-2026-10-16.swift':'PatchFilePanelVerification',
 'file-patches-native-2026-10-13.swift':'FilePatchesVerification',
 'import-patch-native-2026-10-08.swift':'ImportPatchVerification',
 'import-patch-lifecycle-native-2026-10-11.swift':'ImportPatchLifecycleVerification',
 'comparison-output-ownership-native-2026-10-15.swift':'ComparisonOutputOwnershipVerification',
 'two-pane-engine-native-2026-10-12.swift':'TwoPaneEngineVerification',
 'three-pane-engine-native-2026-10-12.swift':'ThreePaneEngineVerification',
 'merge-command-menus-native-2026-10-16.swift':'MergeCommandMenusVerification',
}


class PatchPanelContracts(unittest.TestCase):
    def execute(self,selected,engines=None,*,captures=False,code=0,marker=True):
        builds,calls=[],[];self.last_calls=calls
        with tempfile.TemporaryDirectory(prefix='offline-patch-contract-') as temporary:
            folder=Path(temporary)
            def build(root,sources,directory,**kwargs):
                self.assertEqual(kwargs,{'fixture_mode':'per-file'})
                family=directory.name.removeprefix('family-')
                self.assertEqual([path.name for path in sources[:-1]],list(driver.FIXTURES[family]))
                for source in sources[:-1]:
                    self.assertEqual(source.read_text(),(ROOT/'docs/qa'/source.name).read_text().replace('@main ', '',1))
                main=sources[-1].read_text()
                for case in driver.FAMILIES[family]:self.assertIn('case "'+case+'": try await '+driver.cases[case],main)
                for case in set(driver.cases)-set(driver.FAMILIES[family]):self.assertNotIn('case "'+case+'":',main)
                builds.append(family)
                return directory/'cached-receiver'
            def run(command,**kwargs):
                self.assertEqual(kwargs['cwd'],ROOT)
                self.assertTrue(kwargs['capture_output'] and kwargs['text'])
                self.assertNotIn('timeout',kwargs)  # unchanged owned 300s default
                env=kwargs['env'];case=env['TURTLEGIT_PATCH_PANEL_CASE']
                self.assertEqual(Path(command[0]).parent.name,'family-'+driver.family_for(case))
                self.assertTrue(Path(command[1]).is_dir())
                self.assertEqual(env['GIT_CONFIG_GLOBAL'],'/dev/null')
                self.assertEqual(env['GIT_CONFIG_NOSYSTEM'],'1')
                self.assertEqual(env['GIT_CONFIG_COUNT'],'0')
                calls.append((case,command[2],command[1],env.get('TURTLEGIT_PATCH_PANEL_CAPTURE')))
                return subprocess.CompletedProcess(command,code,'PASS: patch panel family case completed\n' if marker else '', 'original native diagnostics\n')
            with contextlib.redirect_stdout(io.StringIO()):
                driver.run_workflows(ROOT,folder,selected,engines or [Path('/system/git'),Path('/bundled/git')],captures=folder/'captures' if captures else None,build=build,run=run,environ={'TURTLEGIT_PATCH_PANEL_CAPTURE':'foreign capture'})
        return builds,calls

    def test_complete_default_source_inventory_and_actual_dependency_closure(self):
        self.assertEqual(set(ORIGINAL_FIXTURES),{name for files in driver.FIXTURES.values() for name in files})
        self.assertEqual([case for values in driver.FAMILIES.values() for case in values],list(driver.cases))
        for family,files in driver.FIXTURES.items():
            for filename in files:
                text=(ROOT/'docs/qa'/filename).read_text()
                for dependency,symbol in ORIGINAL_FIXTURES.items():
                    if symbol in text:self.assertIn(dependency,files,(family,filename,symbol))
        self.assertEqual(max(map(len,driver.FIXTURES.values())),7)

    def test_ci_four_cases_compile_once_and_preserve_all_eight_runtime_cases(self):
        builds,calls=self.execute(['special','recovery','panel','files'])
        self.assertEqual(builds,['patch'])
        self.assertEqual([(case,git) for case,git,_,_ in calls],[(case,git) for case in ['special','recovery','panel','files'] for git in ['/system/git','/bundled/git']])
        self.assertEqual(len({row[2] for row in calls}),8)
        self.assertTrue(all(row[3] is None for row in calls))

    def test_default_keeps_every_case_and_original_menu_engine_policy(self):
        builds,calls=self.execute(list(driver.cases))
        self.assertEqual(builds,['patch','import','menus'])
        self.assertEqual([(case,git) for case,git,_,_ in calls],[(case,git) for case in driver.cases for git in (['/usr/bin/git'] if case=='menus' else ['/system/git','/bundled/git'])])
        self.assertEqual(len({row[2] for row in calls}),11)

    def test_interleaved_choices_reuse_family_but_keep_requested_runtime_order(self):
        builds,calls=self.execute(['menus','special','import','recovery'])
        self.assertEqual(builds,['menus','patch','import'])
        self.assertEqual([case for case,_,_,_ in calls],['menus','special','special','import','import','recovery','recovery'])

    def test_capture_quarantine_and_first_engine_source_families_unchanged(self):
        _,calls=self.execute(['special','recovery','panel','files','menus'],captures=True)
        for case,git,_,capture in calls:
            self.assertEqual(capture is not None,case in ['special','recovery','panel'] and git=='/system/git')

    def test_nonzero_and_missing_completion_remain_fail_fast(self):
        with self.assertRaises(subprocess.CalledProcessError):self.execute(['special','recovery'],code=9)
        self.assertEqual(len(self.last_calls),1)
        with self.assertRaisesRegex(SystemExit,'without completion'):self.execute(['special','recovery'],marker=False)
        self.assertEqual(len(self.last_calls),1)


if __name__=='__main__':unittest.main()
