#!/usr/bin/env python3
"""Audit pinned PuTTY CLI code, source provenance and signed helper placement."""
import argparse,hashlib,json,plistlib,re,subprocess
from pathlib import Path
from runtime_bundle_layout import code_record
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('runtime',type=Path);args=p.parse_args();runtime=args.runtime
pin=json.loads((ROOT/'Configuration/PuTTYRuntime.json').read_text());manifest=json.loads((runtime/'provenance.json').read_text())
assert manifest['pin']==pin
binary=runtime/'bin/puttygen';record=code_record(binary,runtime)
for name,digest in manifest['files_sha256'].items():
    assert '..' not in Path(name).parts
    if name=='bin/puttygen' and record: assert record['original_sha256']==digest
    else: assert hashlib.sha256((runtime/name).read_bytes()).hexdigest()==digest,name
assert hashlib.sha256((runtime/'Sources/putty.tar.gz').read_bytes()).hexdigest()==pin['putty']['sha256']
assert (runtime/'Licenses/PuTTY-LICENCE.txt').stat().st_size > 500
if not record: assert hashlib.sha256(binary.read_bytes()).hexdigest()==manifest['binary_sha256']['puttygen']
assert set(subprocess.check_output(['lipo','-archs',binary],text=True).split())==set(pin['architectures'])
versions=subprocess.check_output(['xcrun','vtool','-show-build',binary],text=True)
minimums=re.findall(r'\bminos\s+([0-9.]+)',versions);assert len(minimums)==2 and set(minimums)=={pin['deployment_target']}
linkage=subprocess.check_output(['otool','-L',binary],text=True)
for line in linkage.splitlines():
    if '(compatibility version' in line: assert line.strip().startswith(('/usr/lib/','/System/Library/')),line
if manifest.get('signed') or record:
    subprocess.run(['codesign','--verify','--strict',binary],check=True,capture_output=True)
    if manifest.get('sandbox_inherited') or (record and record.get('sandbox_inherited')):
        raw=subprocess.check_output(['codesign','-d','--entitlements',':-',binary],stderr=subprocess.STDOUT)
        xml=raw[raw.index(b'<?xml'):raw.index(b'</plist>')+8]
        assert plistlib.loads(xml)=={'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True}
        print('PuTTY: universal pinned inherited-sandbox helper verified; native signed invocation remains open.');raise SystemExit(0)
version=subprocess.check_output([binary,'--version'],text=True);assert 'Release '+pin['putty']['version'] in version
print('PuTTY: universal macOS 13 CLI, system linkage, licence and reconstruction source verified.')
