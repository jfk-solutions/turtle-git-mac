#!/usr/bin/env python3
"""Focused tests for exact Actions-step capture and bounded failure diagnostics."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import shutil
import shlex
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT/'scripts/ci-step-log.sh'
COLLECTOR = ROOT/'scripts/collect-ci-step-failures.py'
spec = importlib.util.spec_from_file_location('ci_step_failures', COLLECTOR)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class StepCaptureTests(unittest.TestCase):
    def setUp(self):
        # Canonical private roots avoid the platform's /var -> /private/var alias.
        self.temp = tempfile.TemporaryDirectory(dir=Path(tempfile.gettempdir()).resolve())
        self.base = Path(self.temp.name).resolve()
        self.runner = self.base/'runner'; self.runner.mkdir()
        self.workspace = self.base/'workspace'; self.workspace.mkdir()
        self.logs = self.workspace/'build/ci-step-logs'
        self.environment = dict(os.environ, BASH_ENV=str(HELPER), GITHUB_ACTIONS='true',
                                RUNNER_TEMP=str(self.runner), GITHUB_WORKSPACE=str(self.workspace),
                                GIT_CONFIG_COUNT='41')
        self.environment.pop('TURTLEGIT_CI_STEP_LOG_ACTIVE', None)
        self.environment.pop('BASH_EXECUTION_STRING', None)

    def tearDown(self):
        self.temp.cleanup()

    def launch(self, source, name=None, changes=None, command=False):
        identity = name or str(uuid.uuid4())+'.sh'
        script = self.runner/identity
        script.write_text(source)
        environment = dict(self.environment, **(changes or {}))
        arguments = ['/bin/bash', '--noprofile', '--norc', '-e', '-o', 'pipefail']
        arguments += ['-c', source, str(script)] if command else [str(script)]
        if not command:
            environment.pop('BASH_ENV',None)
            arguments=['/bin/bash','--noprofile','--norc','-c','exec 8>&- 9>&-; export BASH_ENV="$1"; shift; exec "$@"','private-launch',str(HELPER)]+arguments
        result = subprocess.run(arguments, cwd=self.workspace, env=environment,
                                capture_output=True, timeout=15)
        return result, script.stem

    def test_top_step_exact_streams_exit_options_umask_and_child_inertness(self):
        shells=['/bin/bash']
        selected=shutil.which('bash')
        if selected and Path(selected).resolve()!=Path('/bin/bash').resolve():shells.append(selected)
        for number,bash in enumerate(shells):
            with self.subTest(shell=bash):
                workspace=self.workspace/('shell-'+str(number));workspace.mkdir()
                logs=workspace/'build/ci-step-logs'
                child=self.runner/(str(uuid.uuid4())+'.sh')
                child.write_text("printf 'child out\\n'; printf 'child err\\n' >&2; printf '%s\\n' \"$GIT_CONFIG_COUNT\" > child-env; umask > child-umask\n")
                identity=str(uuid.uuid4());script=self.runner/(identity+'.sh')
                script.write_text("printf 'top out\\n'; printf 'top err\\n' >&2\nprintf '%s\\n' \"$GIT_CONFIG_COUNT\" > top-env\numask > top-umask\n: > created\n"+shlex.quote(bash)+" "+shlex.quote(str(child))+"\ncaptured=$("+shlex.quote(bash)+" -c 'printf hook-result')\nprintf 'capture=%s\\n' \"$captured\"\nfalse\nprintf 'must not execute\\n'\n")
                environment={key:value for key,value in self.environment.items() if key!='BASH_ENV'}
                environment['GITHUB_WORKSPACE']=str(workspace)
                result=subprocess.run(
                    ['/bin/bash','--noprofile','--norc','-c','exec 8>&- 9>&-; umask 027; export BASH_ENV="$1"; exec "$3" --noprofile --norc -e -o pipefail "$2"','private-launch',str(HELPER),str(script),bash],
                    cwd=workspace,env=environment,capture_output=True,timeout=15)
                self.assertEqual(result.returncode,1)
                self.assertEqual(result.stdout,b'top out\nchild out\ncapture=hook-result\n')
                self.assertEqual(result.stderr,b'top err\nchild err\n')
                self.assertEqual((logs/(identity+'.stdout.log')).read_bytes(),result.stdout)
                self.assertEqual((logs/(identity+'.stderr.log')).read_bytes(),result.stderr)
                self.assertEqual((logs/(identity+'.status')).read_bytes(),b'1\n')
                self.assertEqual(sorted(path.name for path in logs.iterdir()),sorted(identity+suffix for suffix in ('.stdout.log','.stderr.log','.status')))
                self.assertEqual((workspace/'top-env').read_text(),'41\n')
                self.assertEqual((workspace/'child-env').read_text(),'41\n')
                self.assertEqual(int((workspace/'top-umask').read_text().strip(),8),0o27)
                self.assertEqual(int((workspace/'child-umask').read_text().strip(),8),0o27)
                self.assertEqual(stat.S_IMODE((workspace/'created').stat().st_mode),0o640)

    def test_occupied_backup_descriptor_refuses_capture_without_taking_ownership(self):
        for descriptor in (8,9):
            with self.subTest(descriptor=descriptor):
                script=self.runner/(str(uuid.uuid4())+'.sh')
                script.write_text("printf 'original descriptor\\n' >&"+str(descriptor)+"\nprintf 'unaltered\\n'; exit 7\n")
                environment={key:value for key,value in self.environment.items() if key!='BASH_ENV'}
                result=subprocess.run(['/bin/bash','-c','exec '+str(descriptor)+'> descriptor-output; export BASH_ENV="$1"; exec /bin/bash -e "$2"','private-fd',str(HELPER),str(script)],
                                      cwd=self.workspace,env=environment,capture_output=True,timeout=15)
                self.assertEqual((result.returncode,result.stdout,result.stderr),(7,b'unaltered\n',b''))
                self.assertEqual((self.workspace/'descriptor-output').read_text(),'original descriptor\n')
                self.assertFalse(self.logs.exists())

    def test_nonci_nonuuid_command_shell_descendant_and_symlink_are_untouched(self):
        cases = [dict(changes={'GITHUB_ACTIONS':'false'}), dict(name='ordinary.sh'),
                 dict(command=True)]
        for case in cases:
            with self.subTest(case=case):
                result,_ = self.launch("printf 'unchanged\\n'; printf 'error\\n' >&2; exit 7\n", **case)
                self.assertEqual((result.returncode,result.stdout,result.stderr),(7,b'unchanged\n',b'error\n'))
                self.assertFalse(self.logs.exists())
        nested=self.runner/'nested';nested.mkdir();script=nested/(str(uuid.uuid4())+'.sh');script.write_text('exit 9\n')
        result=subprocess.run(['/bin/bash',str(script)],cwd=self.workspace,env=self.environment,capture_output=True,timeout=15)
        self.assertEqual(result.returncode,9);self.assertFalse(self.logs.exists())
        real=self.runner/'real.sh';real.write_text('exit 11\n');link=self.runner/(str(uuid.uuid4())+'.sh');link.symlink_to(real)
        result=subprocess.run(['/bin/bash',str(link)],cwd=self.workspace,env=self.environment,capture_output=True,timeout=15)
        self.assertEqual(result.returncode,11);self.assertFalse(self.logs.exists())

    def test_zero_and_explicit_nonzero_status_are_preserved(self):
        for code in (0,23):
            with self.subTest(code=code):
                result,identity=self.launch('printf \'value\\n\'; exit '+str(code)+'\n')
                self.assertEqual(result.returncode,code)
                self.assertEqual(result.stdout,b'value\n');self.assertEqual(result.stderr,b'')
                self.assertEqual((self.logs/(identity+'.status')).read_text(),str(code)+'\n')


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(dir=Path(tempfile.gettempdir()).resolve())
        self.base=Path(self.temp.name).resolve();self.logs=self.base/'logs';self.logs.mkdir()
        self.output=self.base/'reports'
        self.previous_output=os.environ.pop('GITHUB_OUTPUT',None)

    def tearDown(self):
        if self.previous_output is not None:os.environ['GITHUB_OUTPUT']=self.previous_output
        else:os.environ.pop('GITHUB_OUTPUT',None)
        self.temp.cleanup()

    def record(self,code=1,stdout=b'',stderr=b''):
        identity=str(uuid.uuid4())
        (self.logs/(identity+'.status')).write_text(str(code)+'\n')
        (self.logs/(identity+'.stdout.log')).write_bytes(stdout)
        (self.logs/(identity+'.stderr.log')).write_bytes(stderr)
        return identity

    def test_only_nonzero_failures_and_active_collector_exclusion_without_false_green(self):
        success=self.record(0,stderr=b'error: old output alone is not a failed status\n')
        failed=self.record(17)
        incomplete=str(uuid.uuid4());(self.logs/(incomplete+'.stdout.log')).write_text('not finalized\n')
        active=str(uuid.uuid4());(self.logs/(active+'.stdout.log')).write_text('collector currently running\n')
        github_output=self.base/'github-output';github_output.touch();os.environ['GITHUB_OUTPUT']=str(github_output)
        result=module.collect(self.logs,self.output,'early',active)
        self.assertEqual(result['failed_steps'],1);self.assertEqual(result['successful_statuses'],1)
        self.assertEqual(result['incomplete_steps'],1);self.assertEqual(result['excluded_active_step'],active)
        self.assertTrue(result['present']);self.assertTrue(result['incomplete'])
        self.assertEqual(github_output.read_text(),'present=true\nincomplete=true\n')
        self.assertTrue((self.output/(failed+'.txt')).is_file());self.assertFalse((self.output/(success+'.txt')).exists())
        self.assertFalse((self.output/(active+'.txt')).exists());self.assertFalse((self.output/(incomplete+'.txt')).exists())
        self.assertIn('not a job-success verdict',result['assessment'])

    def test_redaction_and_fatal_traceback_context_survive_large_crash_footer(self):
        secret='ghp_'+'A'*36
        messages=('head context\nAuthorization: Bearer '+secret+'\npassword="not public value"\n'
                  'https://user:private-password@example.invalid/repository\n'
                  'github_pat_'+'B'*60+'\n'
                  '-----BEGIN OPENSSH PRIVATE KEY-----\nprivate-key-payload\n-----END OPENSSH PRIVATE KEY-----\n'
                  'near assertion\nSwift/ErrorType.swift:253: Fatal error: Error raised at top level: Expected menu absent\n'
                  'XCTAssertEqual failed: expected exact owner\nTraceback (most recent call last):\n  private test frame\nAssertionError: dialog refused\n')
        identity=self.record(stderr=(messages+('binary image footer line\n'*9000)+'last footer\n').encode())
        result=module.collect(self.logs,self.output,'end')
        report=(self.output/(identity+'.txt')).read_text()
        for private in (secret,'private-password','not public value','private-key-payload','B'*60):self.assertNotIn(private,report)
        for evidence in ('Expected menu absent','XCTAssertEqual failed','Traceback (most recent call last)','AssertionError: dialog refused','last footer'):
            self.assertIn(evidence,report)
        self.assertIn('[REDACTED',report)
        self.assertLessEqual((self.output/(identity+'.txt')).stat().st_size,module.MAX_FILE_BYTES)
        self.assertGreater(result['steps'][0]['streams']['stderr']['diagnostic_markers'],0)

    def test_late_fatal_context_survives_early_warning_source_snippets(self):
        snippets=('source.swift:1:1: warning: original compiler warning\n'
                  '1 | NSAlert(error:error)\n'
                  '2 | XCTAssertEqual(first,second)\n')*20
        fatal='Fatal error: late concrete ownership assertion\nimportant exact path receipt\n'
        identity=self.record(stderr=(snippets+fatal+'image footer\n'*10000).encode())
        result=module.collect(self.logs,self.output,'late-fatal')
        report=(self.output/(identity+'.txt')).read_text()
        self.assertIn('late concrete ownership assertion',report)
        self.assertIn('important exact path receipt',report)
        self.assertFalse(module.MARKER.search('1 | NSAlert(error:error)'))
        self.assertGreater(result['steps'][0]['streams']['stderr']['retained_latest_contexts'],0)

    def test_symlinks_nonregular_and_malformed_status_are_omitted_safely(self):
        outside=self.base/'private-repository';outside.mkdir();private=outside/'private.txt';private.write_text('do not collect this private payload\n')
        failed=self.record();(self.logs/(failed+'.stdout.log')).unlink();(self.logs/(failed+'.stdout.log')).symlink_to(private)
        malformed=str(uuid.uuid4());(self.logs/(malformed+'.status')).write_text('password=do-not-expose\n')
        linked=str(uuid.uuid4());(self.logs/(linked+'.status')).symlink_to(private)
        pipe=str(uuid.uuid4());os.mkfifo(self.logs/(pipe+'.status'))
        (self.logs/'native-private-repo').symlink_to(outside,target_is_directory=True)
        result=module.collect(self.logs,self.output,'unsafe')
        contents=''.join(path.read_text() for path in self.output.iterdir())
        self.assertNotIn('private payload',contents);self.assertNotIn('do-not-expose',contents)
        self.assertEqual(result['failed_steps'],1);self.assertEqual(result['incomplete_steps'],3)
        self.assertIn('unsafe',(self.output/(failed+'.txt')).read_text())
        self.assertGreater(result['ignored_entries'],0)

    def test_all_output_limits_and_omissions_remain_explicit(self):
        payload=(('compiler context\nerror: actual compiler diagnostic\n'+'ordinary context line\n'*200)*10+'ordinary log line\n'*15000).encode()
        for _ in range(45):self.record(stderr=payload,stdout=payload)
        result=module.collect(self.logs,self.output,'bounded')
        files=list(self.output.iterdir())
        self.assertLessEqual(sum(path.stat().st_size for path in files),module.MAX_TOTAL_BYTES)
        self.assertTrue(all(path.stat().st_size<=module.MAX_FILE_BYTES for path in files if path.suffix=='.txt'))
        self.assertEqual(result['failed_steps'],45)
        self.assertTrue(result['reports_omitted'] or any(item.get('report_truncated') for item in result['steps']))
        self.assertTrue(all(item['streams']['stderr']['selection_truncated'] for item in result['steps']))

    def test_private_key_before_selected_tail_and_overlong_secret_line_do_not_leak(self):
        identity=self.record(stderr=('-----BEGIN RSA PRIVATE KEY-----\n'+'secret material\n'*10000).encode())
        oversized=self.record(stdout=b'password='+b'Z'*(module.MAX_LINE_BYTES+1)+b'\nerror: later omitted for safety\n')
        result=module.collect(self.logs,self.output,'secrets')
        contents=''.join(path.read_text() for path in self.output.iterdir())
        self.assertNotIn('secret material',contents);self.assertNotIn('ZZZZ',contents)
        details=next(item for item in result['steps'] if item['uuid']==oversized)['streams']['stdout']
        self.assertFalse(details['scan_complete']);self.assertIn('overlong',details['omitted_reason'])
        self.assertIn('[REDACTED PRIVATE KEY BLOCK]',(self.output/(identity+'.txt')).read_text())

    def test_prefixed_secrets_signed_queries_quoted_escapes_and_clip_boundaries(self):
        secret='github_pat_'+'B'*50
        payload=('H'*4080+' '+secret+'\n'
                 'AWS_SECRET_ACCESS_KEY=opaque-aws-secret\n'
                 'ACTIONS_RUNTIME_TOKEN="opaque action runtime"\n'
                 'MACOS_CERT_PASSWORD=opaque-cert-secret\n'
                 'password="escaped\\"secret-tail"\n'
                 'Authorization: Bearer opaque-header-secret\n'
                 '{"Authorization": "Basic opaque-json-secret"}\n'
                 'https://user:opaque-url-secret@host/path?sig=opaque-signed-secret&other=value\n'
                 'https://host/path?X-Amz-Signature=opaque-amz-secret\n'
                 'Fatal error: concrete assertion remains\n')
        identity=self.record(stderr=payload.encode())
        result=module.collect(self.logs,self.output,'credentials')
        report=(self.output/(identity+'.txt')).read_text()
        for value in (secret,'opaque-aws-secret','opaque action runtime','opaque-cert-secret','secret-tail','opaque-header-secret','opaque-json-secret','opaque-url-secret','opaque-signed-secret','opaque-amz-secret'):
            self.assertNotIn(value,report)
        self.assertIn('concrete assertion remains',report)
        self.assertTrue(result['failed']);self.assertTrue(result['present'])

    def test_unterminated_quoted_assignment_does_not_expose_its_remainder(self):
        identity=self.record(stderr=b'error: before secret\nMACOS_CERT_PASSWORD="first second\nthird fourth\n')
        result=module.collect(self.logs,self.output,'unterminated')
        report=(self.output/(identity+'.txt')).read_text()
        for value in ('first','second','third','fourth'):self.assertNotIn(value,report)
        self.assertIn('before secret',report)
        self.assertTrue(result['steps'][0]['streams']['stderr']['quoted_secret_open_at_end'])

    def test_incomplete_only_still_publishes_evidence_without_inventing_failed_status(self):
        identity=str(uuid.uuid4());(self.logs/(identity+'.stderr.log')).write_text('no attributable final status\n')
        github_output=self.base/'github-output';github_output.touch();os.environ['GITHUB_OUTPUT']=str(github_output)
        result=module.collect(self.logs,self.output,'incomplete-only')
        self.assertTrue(result['present']);self.assertTrue(result['incomplete']);self.assertFalse(result['failed'])
        self.assertEqual(result['failed_steps'],0)
        self.assertEqual(list(self.output.glob('*.txt')),[])
        self.assertEqual(github_output.read_text(),'present=true\nincomplete=true\n')

    def test_directory_symlinks_and_existing_output_are_not_followed_or_overwritten(self):
        identity=self.record(stderr=b'error: known failure\n')
        alias=self.base/'alias';alias.symlink_to(self.logs,target_is_directory=True)
        result=module.collect(alias,self.output,'refused')
        self.assertEqual(result['failed_steps'],0);self.assertTrue(result['incomplete'])
        self.assertTrue(result['collection_errors']);self.assertFalse((self.output/(identity+'.txt')).exists())
        with self.assertRaises(ValueError):module.collect(self.logs,self.output,'no-overwrite')
        target=self.base/'private-output';target.mkdir();link=self.base/'output-alias';link.symlink_to(target,target_is_directory=True)
        with self.assertRaises(OSError):module.collect(self.logs,link,'refused-output')
        self.assertEqual(list(target.iterdir()),[])


if __name__=='__main__':
    unittest.main()
