#!/usr/bin/env python3
"""Compare native status colors against the pinned upstream C++ color conversion."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request
from native_receiver import build_receiver, run_receiver

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--captures', type=Path)
scope = parser.add_mutually_exclusive_group()
scope.add_argument('--only-text', action='store_true', help='Repeat the affected text receiver after the source oracle has passed.')
scope.add_argument('--only-oracle', action='store_true', help='Check source conversion/settings without repeating the dialog receiver.')
args = parser.parse_args()
if args.captures:
    args.captures = args.captures.absolute(); args.captures.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parent.parent
pin = '7338078f8ddd924b8cddee35f512f2286072136d'
assert json.loads((root / 'docs/upstream.json').read_text())['commit'] == pin
upstream = Path(os.environ.get('TURTLEGIT_COLOR_SOURCE_CHECKOUT', str(root / '.upstream/TortoiseGit')))
source_hashes = {}

def source(path):
    with (root / 'docs/upstream-files.csv').open(newline='') as stream:
        expected = next(row['blob'] for row in csv.DictReader(stream) if row['path'] == path)
    cached = root / 'build/qa/color-source-cache' / pin / Path(path).name
    if (upstream / '.git').exists():
        assert subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip() == pin
        data = subprocess.check_output(['git', '-C', str(upstream), 'show', pin + ':' + path])
    elif cached.is_file():
        data = cached.read_bytes()
    else:
        url = 'https://raw.githubusercontent.com/TortoiseGit/TortoiseGit/' + pin + '/' + path
        with urllib.request.urlopen(url, timeout=30) as response:
            data = response.read()
    actual = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
    if actual != expected:
        raise SystemExit('Pinned color oracle source blob mismatch: ' + path)
    cached.parent.mkdir(parents=True, exist_ok=True); cached.write_bytes(data)
    source_hashes[path] = hashlib.sha256(data).hexdigest()
    return data.decode('utf-8-sig')

with tempfile.TemporaryDirectory(prefix='turtlegit-status-colors-native-') as temporary:
    directory = Path(temporary)
    products = root / 'build/Build/Products/Debug'
    environment = os.environ.copy(); environment['DYLD_FRAMEWORK_PATH'] = str(products)
    environment.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    if not args.only_text:
        theme = source('src/Utils/Theme.cpp')
        colors = source('src/TortoiseProc/Colors.cpp')
        roles = ['Conflict', 'Modified', 'Merged', 'Deleted', 'Added', 'Renamed','CurrentBranch','LocalBranch','RemoteBranch','Tag','Stash','BisectGood','BisectBad','BisectSkip','NoteNode','OtherRef','FilterMatch', *['BranchLine'+str(i) for i in range(1,9)]]
        values = {role.lower(): [int(c.strip(),0) for c in re.search(r'\{ ' + role + r',.*?RGB\(([^)]+)\)', colors).group(1).split(',')] for role in roles}
        values.update({"black":[0,0,0],"white":[255,255,255],"custom":[3,127,249],"bright":[250,240,230]})
        functions = theme[theme.index('void CTheme::RGBtoHSL('):theme.index('std::optional<LRESULT> CTheme::HandleMenuBar')].replace('CTheme::', '')
        header = '#include <algorithm>\n#include <iostream>\n#include <cstdint>\nusing COLORREF=uint32_t; using BYTE=uint8_t;\n#define RGB(r,g,b) (uint32_t(r)|(uint32_t(g)<<8)|(uint32_t(b)<<16))\n#define GetRValue(c) ((c)&255)\n#define GetGValue(c) (((c)>>8)&255)\n#define GetBValue(c) (((c)>>16)&255)\n'
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
        receiver = build_receiver(root, [root / 'docs/qa/status-colors-native-2026-10-09.swift'], directory)
        run_receiver([str(receiver), str(snapshot)], cwd=root, env=environment, check=True)
        print('Pinned oracle inputs:', source_hashes)
        print('Source conversion oracle passed for', len(expected), 'RGB inputs in light/dark/high-contrast modes.', flush=True)
    if args.only_oracle:
        raise SystemExit(0)
    text_receiver = build_receiver(root, [root / 'docs/qa/status-text-native-2026-10-15.swift'], directory)
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        fixture = directory / str(index) / 'Harbor'; fixture.mkdir(parents=True)
        print('Checking native status text with ' + str(git), flush=True)
        result = run_receiver([str(text_receiver), str(fixture), str(git.absolute()), *([str(args.captures)] if args.captures and index == 0 else [])], cwd=root, env=environment, capture_output=True, text=True)
        print(result.stdout, end=''); print(result.stderr, end=''); result.check_returncode()
        if 'PASS: Status text completed:' not in result.stdout:
            raise SystemExit('Status receiver exited before its completion marker.')
