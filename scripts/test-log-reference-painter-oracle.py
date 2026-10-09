#!/usr/bin/env python3
"""Compare native badge geometry/colors with unchanged bodies from the pinned source.

Portable handle/CRect adapters record drawing calls; this does not execute GDI or
establish raster, font, clipping, selected-row or physical screenshot equivalence.
"""
import json
from pathlib import Path
import platform
import random
import subprocess
import tempfile
import os

root = Path(__file__).resolve().parent.parent
upstream = root / '.upstream/TortoiseGit'
pin = '7338078f8ddd924b8cddee35f512f2286072136d'
assert subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip() == pin
assert not subprocess.check_output(['git', '-C', str(upstream), 'status', '--porcelain'], text=True).strip()

def source(path):
    return subprocess.check_output(['git', '-C', str(upstream), 'show', pin + ':' + path]).decode().replace('\r\n', '\n')

def body(text, signature):
    start = text.index(signature)
    return text[start:text.index('\n}\n', start) + 3]

log = source('src/TortoiseProc/GitLogListBase.cpp')
tracking = body(log, 'void DrawTrackingRoundRect(')
mix = body(source('src/TortoiseProc/Colors.cpp'), 'COLORREF CColors::MixColors(')
triangle = next(line.strip() for line in log.splitlines() if 'POINT trianglept[3]' in line)
adapter = r'''
#include <iostream>
#include <vector>
#include <array>
#include <cstdint>
using COLORREF=uint32_t;
using HDC=int; using HBRUSH=int; using HPEN=int;
constexpr int PS_NULL=0;
struct POINT { int x,y; };
struct CRect {
 int left,top,right,bottom;
 void DeflateRect(int x,int y) { left+=x; right-=x; top+=y; bottom-=y; }
 void OffsetRect(int x,int y) { left+=x; right+=x; top+=y; bottom+=y; }
};
std::vector<std::array<int,4>> rounds;
int CreatePen(int,int,int) { return 1; }
int SelectObject(int,int) { return 1; }
int CreateSolidBrush(COLORREF) { return 1; }
void DeleteObject(int) {}
void RoundRect(int,int l,int t,int r,int b,int dx,int dy) {
 if(dx!=4 || dy!=4) std::abort(); rounds.push_back({l,t,r,b});
}
struct CColors { static COLORREF MixColors(COLORREF,COLORREF,unsigned char); };
'''
main = r'''
int main() {
 int l,t,r,b,red,green,blue,target,amount;
 while(std::cin>>l>>t>>r>>b>>red>>green>>blue>>target>>amount) {
  CRect rect{l,t,r,b}; rounds.clear(); DrawTrackingRoundRect(0,rect,0,0);
  auto color=CColors::MixColors(red|(green<<8)|(blue<<16),target|(target<<8)|(target<<16),amount);
  for(auto round: rounds) for(int n:round) std::cout<<n<<' ';
  std::cout<<(color&255)<<' '<<((color>>8)&255)<<' '<<((color>>16)&255)<<' ';
  CRect rt=rect; rt.right+=8;
  TRIANGLE
  for(auto p:trianglept) std::cout<<p.x<<' '<<p.y<<' ';
  std::cout<<'\n';
 }
}
'''.replace('TRIANGLE', triangle)
randomizer = random.Random(20261009)
rows = []
for channel in range(256):
    for target in [0, 255]:
        for amount in [50, 100]:
            x, y = randomizer.randint(-100, 100), randomizer.randint(-100, 100)
            rows.append([x, y, x+randomizer.randint(8, 500), y+randomizer.randint(8, 100), channel, (channel*7)%256, (channel*13)%256, target, amount])
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-reference-painter-oracle-') as temporary:
    directory = Path(temporary)
    cpp = directory/'oracle.cpp'; cpp.write_text(adapter + tracking + mix + main)
    executable = directory/'source-oracle'
    subprocess.run(['xcrun', 'clang++', '-std=c++17', str(cpp), '-o', str(executable)], check=True)
    input_bytes = ''.join(' '.join(map(str,row))+'\n' for row in rows).encode()
    expected = [list(map(int,line.split())) for line in subprocess.check_output([str(executable)], input=input_bytes).decode().splitlines()]
    receiver = directory/'native-oracle'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-target', platform.machine()+'-apple-macos13.0', '-I', str(products), '-F', str(products), str(root/'Sources/TurtleGitMac/LogReferenceDrawing.swift'), str(root/'docs/qa/log-reference-painter-oracle-2026-10-09.swift'), '-framework', 'TurtleGitCore', '-o', str(receiver)], check=True)
    environment = os.environ.copy(); environment['DYLD_FRAMEWORK_PATH'] = str(products)
    actual = json.loads(subprocess.check_output([str(receiver)], input=json.dumps(rows).encode(), env=environment))
    assert len(actual)==len(expected)==len(rows)
    for index, (wanted, got) in enumerate(zip(expected,actual)):
        assert wanted==got, {'row': rows[index], 'source': wanted, 'native': got}
print('PASS: 1024 pinned-source tracking rectangles, annotated triangle coordinates and signed border-color mixes; no GDI/raster claim')
