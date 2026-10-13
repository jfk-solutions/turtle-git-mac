#!/usr/bin/env python3
"""Grouped real CLI/template checks in isolated working trees; no GUI launch."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--tool', type=Path, required=True)
parser.add_argument('--git', action='append', required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
tool = args.tool.resolve()
for engine in args.git:
    engine = str(Path(engine).absolute())
    with tempfile.TemporaryDirectory(prefix='TurtleGitWCRev-QA-') as temporary:
        repo = Path(temporary)/'repo'; repo.mkdir()
        env = dict(os.environ, TURTLEGIT_WCREV_GIT=engine, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_TERMINAL_PROMPT='0')
        def git(*arguments):
            return subprocess.run([engine,'-C',str(repo),*arguments],env=env,check=True,capture_output=True,timeout=20).stdout
        def run(*arguments, code=0):
            result = subprocess.run([str(tool),*map(str,arguments)],env=env,capture_output=True,timeout=20)
            assert result.returncode == code, (arguments,result.returncode,result.stdout,result.stderr)
            return result.stdout
        git('init','-b','main')
        for key,value in [('user.name','WCRev 雪'),('user.email','wcrev@example.invalid'),('core.hooksPath','/dev/null'),('commit.gpgsign','false')]: git('config',key,value)
        source = repo/'source 雪\n.txt'; source.write_bytes(b'baseline\n'); git('add','--',source.name); git('commit','-m','Baseline')
        git('tag','-a','release','-m','Release')
        head = git('rev-parse','HEAD').strip().decode(); index = (repo/'.git/index').read_bytes()
        value = json.loads(run('--json',repo))
        assert value['revision'] == head and value['branch'] == 'main' and value['tagged'] and value['versioned']
        assert value['commitCount'] == 1 and value['author'] == 'WCRev 雪'
        run(repo,'-mUq')
        # Output lives outside the working tree, and unchanged expansion does
        # not rewrite its timestamps. Exercise both pinned upstream templates.
        for name,encoding in [('Test.tmpl','utf-8'),('TestW.tmpl','utf-16-le')]:
            template = root/'Tests/TurtleGitCoreTests/Fixtures/WorkingCopyRevision'/name
            output = Path(temporary)/(name+'.out')
            run(repo,template,output,'-q')
            text = output.read_text(encoding=encoding)
            assert '$WC' not in text and head in text and 'Not modified' in text
            # The official template contains NOW fields, which can change with
            # time. Test timestamp reuse using a deterministic revision template.
        template = Path(temporary)/'stable.in'; template.write_bytes(b'\xff $WCREV=7$ $WCBRANCH$\r\n')
        output = Path(temporary)/'stable.out'
        run(repo,template,output,'-q'); stamp = output.stat().st_mtime_ns
        run(repo,template,output,'-q'); assert output.stat().st_mtime_ns == stamp
        assert output.read_bytes() == b'\xff ' + head[:7].encode() + b' main\r\n'
        run(repo,template,output,'-dq',code=9)
        exclusive = Path(temporary)/'exclusive.out'; run(repo,template,exclusive,'-dq')
        assert exclusive.read_bytes() == output.read_bytes()
        assert run(repo,'-q') == b''
        assert 'HEAD is' in run(repo,'-e').decode('utf-16-le')
        assert git('rev-parse','HEAD').strip().decode() == head and (repo/'.git/index').read_bytes() == index and source.read_bytes() == b'baseline\n'
        source.write_bytes(b'dirty\n'); run(repo,'-mq',code=7)
        source.write_bytes(b'baseline\n')
        (repo/'untracked').write_bytes(b'new'); run(repo,'-uq',code=11)
        git('add','untracked'); run(repo,'-uq',code=11)
        assert not json.loads(run('--json',repo/'untracked'))['versioned']
        run(Path(temporary)/'missing',code=2)
        run(Path(temporary),code=10)
        run(repo,'bad-switch',code=1)
        print('WCRev CLI passed:',engine,'upstream byte/UTF-16 templates, JSON/tag/identity/count, flags/error codes, exclusive write and stable timestamps; HEAD/index/file preserved during read/template operations. No GUI instances launched.')
