#!/usr/bin/env python3
"""Compile pinned WaterEffect.cpp with native integer shims and check RGB oracles."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import urllib.request
root=Path(__file__).resolve().parent.parent;pin=json.loads((root/'docs/upstream.json').read_text())['commit']
with (root/'docs/upstream-files.csv').open(newline='') as stream:blobs={r['path']:r['blob'] for r in csv.DictReader(stream)}
def source(name):
    path='src/Utils/MiscUI/'+name;checkout=root/'.upstream/TortoiseGit';cache=root/'build/qa/about-water-source'/pin/name
    if (checkout/'.git').exists():data=subprocess.check_output(['git','-C',str(checkout),'show',pin+':'+path])
    elif cache.exists():data=cache.read_bytes()
    else:
        with urllib.request.urlopen('https://raw.githubusercontent.com/TortoiseGit/TortoiseGit/'+pin+'/'+path,timeout=30) as stream:data=stream.read()
    assert hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()==blobs[path],path
    cache.parent.mkdir(parents=True,exist_ok=True);cache.write_bytes(data)
    return data.decode('utf-8-sig').replace('\r\n','\n')
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--write',action='store_true');args=parser.parse_args()
cases=[{'width':4,'height':4,'density':2},{'width':10,'height':8,'density':2},{'width':12,'height':10,'density':5},{'width':468,'height':64,'density':2}]
with tempfile.TemporaryDirectory(prefix='turtlegit-water-source-') as temporary:
    folder=Path(temporary)
    (folder/'WaterEffect.h').write_text(source('WaterEffect.h'))
    (folder/'WaterEffect.cpp').write_text(source('WaterEffect.cpp').replace('#include "stdafx.h"',''))
    (folder/'native.h').write_text('''#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <memory>
using DWORD=uint32_t;using COLORREF=uint32_t;
#define SecureZeroMemory(p,n) memset(p,0,n)
#define GetRValue(c) (uint8_t((c)&255U))
#define GetGValue(c) (uint8_t(((c)>>8)&255U))
#define GetBValue(c) (uint8_t(((c)>>16)&255U))
#define RGB(r,g,b) (uint32_t(r)|(uint32_t(g)<<8)|(uint32_t(b)<<16))
''')
    (folder/'main.cpp').write_text(r'''
#include <iostream>
#include <vector>
#include <iomanip>
#define private public
#include "WaterEffect.h"
#undef private
int main(int argc,char **argv) {
 int w=atoi(argv[1]),h=atoi(argv[2]),density=atoi(argv[3]);
 CWaterEffect effect;effect.Create(w,h);effect.m_iDensity=density;
 std::vector<DWORD> input(w*h),output(w*h);
 for(int i=0;i<w*h;i++) input[i]=0xFF000000U|((i*13+17)&255U)|(((i*7+23)&255U)<<8)|(((i*3+91)&255U)<<16);
 output=input;
 for(int frame=0;frame<24;frame++) {
  if(frame==0) effect.Blob(w/2,h/2,2,800,effect.m_iHpage);
  if(frame==3) effect.Blob(0,1,3,50,effect.m_iHpage);
  if(frame==7) effect.Blob(w-1,h-2,3,-300,effect.m_iHpage);
  if(frame==11) effect.Blob(w/2,h/2,10,1600,effect.m_iHpage);
  if(frame==14) effect.SmoothWater(effect.m_iHpage);
  effect.Render(input.data(),output.data());
  uint64_t hash=14695981039346656037ULL;
  for(DWORD p:output) {hash^=(p&0xFFFFFFU);hash*=1099511628211ULL;}
  std::cout<<std::hex<<std::setw(16)<<std::setfill('0')<<hash<<'\n';
 }
}
''')
    exe=folder/'water'
    subprocess.run(['xcrun','clang++','-std=c++17','-O2','-include',str(folder/'native.h'),str(folder/'main.cpp'),str(folder/'WaterEffect.cpp'),'-o',str(exe)],check=True,timeout=120)
    for case in cases:case['rgb_frame_checksums']=subprocess.check_output([str(exe),str(case['width']),str(case['height']),str(case['density'])],text=True,timeout=30).splitlines()
result={'upstream_commit':pin,'scope':'Original WaterEffect.cpp with DWORD/COLORREF/memory/color shims; RGB checksums exclude native-preserved alpha. Explicit source drop coordinates; 24 frames include smoothing.','cases':cases}
target=root/'Tests/TurtleGitCoreTests/Fixtures/WaterEffect/oracle.json'
if args.write:target.parent.mkdir(parents=True,exist_ok=True);target.write_text(json.dumps(result,indent=2)+'\n')
else:assert json.loads(target.read_text())==result,'Water source oracle changed; review pinned source and native adaptation.'
print('PASS: original pinned WaterEffect renderer, four sizes/densities, 96 RGB frames including edge blobs and smoothing.')
