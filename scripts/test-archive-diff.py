#!/usr/bin/env python3
"""Native ZIP association/readonly comparison; private real stored/deflated archives."""
import argparse, os, tempfile, zipfile
from pathlib import Path
from native_receiver import build_receiver, run_receiver
parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('--only',choices=['archive','scripts'],action='append'); args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='TurtleGitArchiveDiff-') as temporary:
    directory=Path(temporary)
    for name,entries in [('old.zip',[('old.txt',b'old'),('folder/child.txt',b'child')]),('new.zip',[('雪.txt',b'new'),('folder/child.txt',b'changed')])]:
        with zipfile.ZipFile(directory/name,'w',compression=zipfile.ZIP_DEFLATED) as archive:
            for path,data in entries:
                entry=zipfile.ZipInfo(path,date_time=(2024,1,2,3,4,6)); entry.compress_type=zipfile.ZIP_DEFLATED
                archive.writestr(entry,data)
    library=root/'build/Build/Products/Debug/TurtleGitCore.framework/TurtleGitCore'
    binary=library.read_bytes(); (directory/'old.dylib').write_bytes(binary)
    changed=bytearray(binary); changed[-1] ^= 1; (directory/'new.dylib').write_bytes(changed)
    for case,source,marker in [('archive','zip-inventory-native-2026-10-16.swift','PASS: actual ZIP association routing'),('scripts','bundled-comparison-native-2026-10-16.swift','PASS: real Mach-O binary native reports')]:
        if args.only and case not in args.only: continue
        executable=build_receiver(root,[root/'docs/qa'/source],directory)
        env=os.environ.copy(); env['DYLD_FRAMEWORK_PATH']=str(root/'build/Build/Products/Debug')
        result=run_receiver([str(executable),str(directory)],cwd=root,env=env,capture_output=True,text=True)
        print(result.stdout,end='',flush=True); print(result.stderr,end='',flush=True); result.check_returncode()
        if marker not in result.stdout: raise SystemExit('Missing bundled comparison completion assertion: '+case)
