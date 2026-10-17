#!/usr/bin/env python3
"""Check immutable helper payload, source kit, architectures and system linkage."""
import hashlib,json,plistlib,re,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1]);manifest=json.loads((root/'provenance.json').read_text())
assert manifest['lexilla_commit']=='ef08a1a00ce151ccdddf7da700fbe1a4934a9c71'
for name,digest in manifest['files'].items():assert hashlib.sha256((root/name).read_bytes()).hexdigest()==digest,name
assert hashlib.sha256((root/'Sources/lexilla.tar.gz').read_bytes()).hexdigest()==manifest['sha256']
assert hashlib.sha256((root/'Sources/build/Sources/TurtleGitLexilla/main.cpp').read_bytes()).hexdigest()==manifest['adapter_sha256']
arches=subprocess.check_output(['lipo','-archs',root/'lexilla'],text=True).split()
assert set(arches)=={'arm64','x86_64'}
for arch in arches:
    links=subprocess.check_output(['otool','-arch',arch,'-L',root/'lexilla'],text=True)
    for line in links.splitlines()[1:]:
        if '(compatibility version' in line:assert line.strip().startswith(('/usr/lib/','/System/Library/')),line
    info=subprocess.check_output(['xcrun','vtool','-arch',arch,'-show-build',root/'lexilla'],text=True)
    assert 'minos 13.0' in info,info
if manifest.get('sandbox_inherited'):
    assert manifest.get('signed') is True, 'Inherited Lexilla manifest must record signing'
if manifest.get('signed'):
    assert re.fullmatch(r'[0-9a-f]{64}',manifest['unsigned_binary_sha256'])
    subprocess.run(['codesign','--verify','--strict',root/'lexilla'],check=True)
    if manifest.get('sandbox_inherited'):
        signature=subprocess.run(['codesign','-d','--entitlements',':-',root/'lexilla'],capture_output=True,check=True)
        assert plistlib.loads(signature.stdout)=={'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True}
        # The source helper already executed before signing. Execute this copy
        # only from an actual sandboxed parent; Python cannot supply inheritance.
        print('Lexilla: source, payload, both architectures/linkage and inherited signature verified; signed parent invocation remains required.')
        raise SystemExit(0)
assert 'ef08a1a00ce151ccdddf7da700fbe1a4934a9c71' in subprocess.check_output([root/'lexilla','--version'],text=True)
print('Verified pinned universal Lexilla helper, licenses, immutable styles and reconstruction source.')
