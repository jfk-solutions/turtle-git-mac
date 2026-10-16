#!/usr/bin/env python3
"""Native ZIP association/readonly comparison; private real stored/deflated archives."""
import os, tempfile, zipfile
from pathlib import Path
from native_receiver import build_receiver, run_receiver
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='TurtleGitArchiveDiff-') as temporary:
    directory=Path(temporary)
    for name,entries in [('old.zip',[('old.txt',b'old'),('folder/child.txt',b'child')]),('new.zip',[('雪.txt',b'new'),('folder/child.txt',b'changed')])]:
        with zipfile.ZipFile(directory/name,'w',compression=zipfile.ZIP_DEFLATED) as archive:
            for path,data in entries:
                entry=zipfile.ZipInfo(path,date_time=(2024,1,2,3,4,6)); entry.compress_type=zipfile.ZIP_DEFLATED
                archive.writestr(entry,data)
    executable=build_receiver(root,[root/'docs/qa/zip-inventory-native-2026-10-16.swift'],directory)
    env=os.environ.copy(); env['DYLD_FRAMEWORK_PATH']=str(root/'build/Build/Products/Debug')
    result=run_receiver([str(executable),str(directory)],cwd=root,env=env,capture_output=True,text=True)
    print(result.stdout,end='',flush=True); print(result.stderr,end='',flush=True); result.check_returncode()
    if 'PASS: actual ZIP association routing' not in result.stdout: raise SystemExit('Missing archive completion assertion')
