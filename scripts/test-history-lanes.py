#!/usr/bin/env python3
"""Compile pinned Lanes/updateLanes and compare native Swift states on deterministic DAGs."""
import hashlib
import json
from pathlib import Path
import random
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
upstream = root/'.upstream/TortoiseGit'
pin = '7338078f8ddd924b8cddee35f512f2286072136d'
assert subprocess.check_output(['git','-C',str(upstream),'rev-parse','HEAD'],text=True).strip() == pin
header = (upstream/'src/TortoiseProc/lanes.h').read_text(encoding='utf-8-sig').replace('#include "githash.h"','')
implementation = (upstream/'src/TortoiseProc/lanes.cpp').read_text(encoding='utf-8-sig').replace('#include "stdafx.h"','')
vector = (upstream/'src/TortoiseProc/LogDataVector.cpp').read_text(encoding='utf-8-sig')
update = vector[vector.index('void CLogDataVector::updateLanes('):].replace('CLogDataVector::','')
fixtures = []
def add(name, parents, first=False, boundaries=()):
    rows=[{'hash':str(i),'parents':list(map(str,p)),'boundary':i in boundaries} for i,p in enumerate(parents)]
    fixtures.append({'name':name,'firstParent':first,'rows':rows})
add('linear',[[1],[2],[]])
add('diamond',[[1,2],[3],[3],[]])
add('octopus-disconnected',[[1,2,3],[],[],[],[]])
add('criss-cross',[[1,2],[3,4],[4,3],[5],[5],[]])
add('merge-first-parent',[[1,2],[3],[3],[]],True)
add('boundary',[[1,2],[3],[3],[]],False,(1,3))
rng=random.Random(7338078)
for case in range(80):
    size=rng.randint(5,35)
    parents=[rng.sample(list(range(i+1,size)),rng.randint(0,min(4,size-i-1))) for i in range(size)]
    add('dag-'+str(case),parents,case%3==0,(size-1,) if case%7==0 else ())
adapter='''#include <algorithm>
#include <string>
#include <vector>
#include <sstream>
#include <iostream>
using std::min;
#define TRUE 1
class CGitHash { public: std::string value; CGitHash()=default; CGitHash(std::string s):value(s){} bool operator==(const CGitHash& b) const {return value==b.value;} void Empty(){value.clear();} };
'''
driver='''
struct GitRevLoglist { CGitHashList m_ParentHash; std::vector<Lanes::LaneType> m_Lanes; bool boundary=false; size_t ParentsCount() const{return m_ParentHash.size();} int IsBoundary() const{return boundary;} };
'''+update+'''
int main(){ Lanes l; std::string line; while(std::getline(std::cin,line)) {std::istringstream s(line); std::string hash,parents; int boundary,first; s>>hash>>parents>>boundary>>first; GitRevLoglist c; c.boundary=boundary; if(parents!="-"){std::istringstream p(parents);std::string h;while(std::getline(p,h,','))c.m_ParentHash.emplace_back(h);} updateLanes(c,l,CGitHash(hash),first); for(auto t:c.m_Lanes)std::cout<<int(t)<<","; std::cout<<";"<<l.activeLane<<"\\n";} }
'''
with tempfile.TemporaryDirectory(prefix='turtlegit-history-lanes-') as temporary:
    directory=Path(temporary)
    # Only adapters/header visibility differ; the actual state/update bodies are compiled verbatim.
    (directory/'lanes.h').write_text(adapter+'\n#define private public\n'+header+'\n#undef private\n')
    (directory/'lanes.cpp').write_text(implementation)
    (directory/'oracle.cpp').write_text('#include "lanes.h"\n'+driver)
    oracle=directory/'oracle'
    subprocess.run(['xcrun','clang++','-std=c++17',str(directory/'lanes.cpp'),str(directory/'oracle.cpp'),'-o',str(oracle)],check=True)
    for fixture in fixtures:
        payload=''.join(row['hash']+' '+(','.join(row['parents']) or '-')+' '+str(int(row['boundary']))+' '+str(int(fixture['firstParent']))+'\n' for row in fixture['rows'])
        output=subprocess.check_output([str(oracle)],input=payload,text=True).splitlines()
        fixture['expected']=[list(map(int,line.split(';')[0].strip(',').split(','))) for line in output]
        fixture['active']=[int(line.split(';')[1]) for line in output]
    snapshot=directory/'fixtures.json';snapshot.write_text(json.dumps(fixtures))
    receiver=directory/'history-lanes-receiver'
    subprocess.run(['xcrun','swiftc','-parse-as-library',str(root/'Sources/TurtleGitCore/HistoryLanes.swift'),str(root/'docs/qa/history-lanes-native-2026-10-09.swift'),'-o',str(receiver)],check=True)
    subprocess.run([str(receiver),str(snapshot)],check=True)
    print('Pinned state source SHA:',{p:hashlib.sha256((upstream/p).read_bytes()).hexdigest() for p in ['src/TortoiseProc/lanes.h','src/TortoiseProc/lanes.cpp','src/TortoiseProc/LogDataVector.cpp']})
    print('Fixture SHA:',hashlib.sha256(snapshot.read_bytes()).hexdigest())
