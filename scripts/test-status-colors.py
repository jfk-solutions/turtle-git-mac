#!/usr/bin/env python3
"""Compare native status colors against the pinned upstream C++ color conversion."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
upstream = root / '.upstream/TortoiseGit'
pin = '7338078f8ddd924b8cddee35f512f2286072136d'
assert subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip() == pin
theme = (upstream / 'src/Utils/Theme.cpp').read_text(encoding='utf-8-sig')
colors = (upstream / 'src/TortoiseProc/Colors.cpp').read_text(encoding='utf-8-sig')
roles = ['Conflict', 'Modified', 'Merged', 'Deleted', 'Added', 'Renamed']
values = {role.lower(): [int(c.strip()) for c in re.search(r'\{ ' + role + r',.*?RGB\(([^)]+)\)', colors).group(1).split(',')] for role in roles}
functions = theme[theme.index('void CTheme::RGBtoHSL('):theme.index('std::optional<LRESULT> CTheme::HandleMenuBar')].replace('CTheme::', '')
header = '#include <algorithm>\n#include <iostream>\n#include <cstdint>\nusing COLORREF=uint32_t; using BYTE=uint8_t;\n#define RGB(r,g,b) (uint32_t(r)|(uint32_t(g)<<8)|(uint32_t(b)<<16))\n#define GetRValue(c) ((c)&255)\n#define GetGValue(c) (((c)>>8)&255)\n#define GetBValue(c) (((c)>>16)&255)\n'
with tempfile.TemporaryDirectory(prefix='turtlegit-status-colors-native-') as temporary:
    directory = Path(temporary)
    cpp = directory / 'reference.cpp'
    cpp.write_text(header + functions + '\nint main(int argc,char**argv) { auto c=RGB(std::stoi(argv[1]),std::stoi(argv[2]),std::stoi(argv[3])); if(std::stoi(argv[4])) { float h,s,l; RGBtoHSL(c,h,s,l); l=100.0f-l; if(!std::stoi(argv[5])) l=std::clamp(l,5.0f,90.0f); c=HSLtoRGB(h,s,l); } std::cout<<GetRValue(c)<<","<<GetGValue(c)<<","<<GetBValue(c); }\n')
    oracle = directory / 'reference'
    subprocess.run(['xcrun', 'clang++', '-std=c++17', str(cpp), '-o', str(oracle)], check=True)
    expected = {}
    for role, rgb in values.items():
        expected[role] = {}
        for mode, dark, high_contrast in [('light',0,0),('dark',1,0),('highContrastDark',1,1)]:
            output = subprocess.check_output([str(oracle), *map(str,rgb), str(dark), str(high_contrast)], text=True)
            expected[role][mode] = list(map(int,output.split(',')))
    snapshot = directory / 'expected.json'; snapshot.write_text(json.dumps(expected))
    products = root / 'build/Build/Products/Debug'
    receiver = directory / 'status-colors-native-receiver'
    subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5','-target',platform.machine()+'-apple-macos13.0','-I',str(products),'-F',str(products),str(root/'Sources/TurtleGitMac/Appearance.swift'),str(root/'docs/qa/status-colors-native-2026-10-09.swift'),'-framework','TurtleGitCore','-o',str(receiver)],check=True)
    environment=os.environ.copy(); environment['DYLD_FRAMEWORK_PATH']=str(products)
    subprocess.run([str(receiver),str(snapshot)],env=environment,check=True)
    print('Pinned oracle inputs:', {p:hashlib.sha256((upstream/p).read_bytes()).hexdigest() for p in ['src/Utils/Theme.cpp','src/TortoiseProc/Colors.cpp']})
    print('C++ reference RGB:', json.dumps(expected,sort_keys=True))
