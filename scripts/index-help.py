#!/usr/bin/env python3
"""Verify copied help resources and create Apple's local search/anchor index."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys

app=Path(sys.argv[1])
book=app/'Contents/Resources/TurtleGitHelp.help'
manifest=json.loads((book/'Contents/Resources/manifest.json').read_text())
for name,digest in manifest['files'].items():
    path=book/name
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest()!=digest:
        raise SystemExit('Missing/stale help resource: '+name)
locale=book/'Contents/Resources/en.lproj'
index=locale/'TurtleGitHelp.helpindex'
subprocess.run(['/usr/bin/hiutil','-I','lsm','-C','-a','-s','en','-f',str(index),str(locale)],check=True,timeout=60)
if not index.is_file() or index.stat().st_size==0:raise SystemExit('Apple Help index was not generated.')
print('Indexed bundled Mac help:',index.stat().st_size,'bytes')
