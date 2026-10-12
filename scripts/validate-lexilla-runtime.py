#!/usr/bin/env python3
"""Check immutable helper payload, source kit, architectures and system linkage."""
import hashlib,json,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1]);manifest=json.loads((root/'provenance.json').read_text())
assert manifest['lexilla_commit']=='ef08a1a00ce151ccdddf7da700fbe1a4934a9c71'
for name,digest in manifest['files'].items():assert hashlib.sha256((root/name).read_bytes()).hexdigest()==digest,name
assert hashlib.sha256((root/'Sources/lexilla.tar.gz').read_bytes()).hexdigest()==manifest['sha256']
assert hashlib.sha256((root/'Sources/build/Sources/TurtleGitLexilla/main.cpp').read_bytes()).hexdigest()==manifest['adapter_sha256']
arches=subprocess.check_output(['lipo','-archs',root/'lexilla'],text=True).split()
assert set(arches)=={'arm64','x86_64'}
assert 'ef08a1a00ce151ccdddf7da700fbe1a4934a9c71' in subprocess.check_output([root/'lexilla','--version'],text=True)
for arch in arches:
    links=subprocess.check_output(['otool','-arch',arch,'-L',root/'lexilla'],text=True)
    for line in links.splitlines()[1:]:
        if '(compatibility version' in line:assert line.strip().startswith(('/usr/lib/','/System/Library/')),line
    info=subprocess.check_output(['xcrun','vtool','-arch',arch,'-show-build',root/'lexilla'],text=True)
    assert 'minos 13.0' in info,info
print('Verified pinned universal Lexilla helper, licenses, immutable styles and reconstruction source.')
