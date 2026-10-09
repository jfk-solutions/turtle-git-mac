#!/usr/bin/env python3
"""Compare Core visible/rolled/lane snapshots with compiled pinned source filters and walk."""
import hashlib,json,os,platform,random,subprocess,tempfile
from pathlib import Path
root=Path(__file__).resolve().parent.parent;upstream=root/'.upstream/TortoiseGit'
pin='7338078f8ddd924b8cddee35f512f2286072136d'
assert subprocess.check_output(['git','-C',str(upstream),'rev-parse','HEAD'],text=True).strip()==pin
read=lambda p:(upstream/p).read_text(encoding='utf-8-sig')
header=read('src/TortoiseProc/lanes.h').replace('#include "githash.h"','')
implementation=read('src/TortoiseProc/lanes.cpp').replace('#include "stdafx.h"','')
vector=read('src/TortoiseProc/LogDataVector.cpp');update=vector[vector.index('void CLogDataVector::updateLanes('):].replace('CLogDataVector::','')
base=read('src/TortoiseProc/GitLogListBase.cpp')
filters=base[base.index('bool CGitLogListBase::ShouldShowAnyFilter()'):base.index('void CGitLogListBase::ShowGraphColumn(')]
a=base.index('\t\t\tbool visible;',base.index('auto rollUpStatesSharedPtr'))
b=base.index('\n\t\t\tif (visible && !filter(',a)
forced=base[a:b]
searchFilter=base[b:base.index("\n\t\t\tthis->m_critSec.Lock();",b)]
adapter='''#include <algorithm>
#include <string>
#include <vector>
#include <sstream>
#include <iostream>
#include <unordered_map>
#include <unordered_set>
using std::min;
#define TRUE 1
class CGitHash {public:std::string value;CGitHash()=default;CGitHash(std::string s):value(s){}bool operator==(const CGitHash& b)const{return value==b.value;}void Empty(){value.clear();}};
namespace std {template<>struct hash<CGitHash>{size_t operator()(const CGitHash& h)const{return hash<string>{}(h.value);}};}
'''
record='''
using CString=std::string;
struct CStringUtils{static bool StartsWith(const CString& s,const wchar_t* p){std::wstring wide(p);std::string prefix(wide.begin(),wide.end());return s.rfind(prefix,0)==0;}};
using MAP_HASH_NAME=std::unordered_map<CGitHash,std::vector<CString>>;
struct GitRevLoglist{CGitHash m_CommitHash;CGitHashList m_ParentHash;std::vector<Lanes::LaneType>m_Lanes;bool matches=true,boundary=false,m_RolledUp=false,m_RolledUpIsForced=false;size_t ParentsCount()const{return m_ParentHash.size();}int IsBoundary()const{return boundary;}};
'''
record+='bool filter(GitRevLoglist* row,void*,const MAP_HASH_NAME&){return row->matches;}\n'
controller='''
class CGitLogListBase{public:
 enum{FILTERSHOW_REFS=1,FILTERSHOW_MERGEPOINTS=2,FILTERSHOW_ANYCOMMIT=4,LOGLIST_SHOWLOCALBRANCHES=1,LOGLIST_SHOWREMOTEBRANCHES=2,LOGLIST_SHOWTAGS=4,LOGLIST_SHOWSTASH=8,LOGLIST_SHOWBISECT=16};
 enum class RollUpState{Expand,Collapse};
 int m_ShowFilter=7,m_ShowRefMask=63;CGitHash m_HeadHash;
 bool ShouldShowAnyFilter();bool ShouldShowRefsFilter(GitRevLoglist*,const MAP_HASH_NAME&);bool ShouldShowMergePointsFilter(GitRevLoglist*,const std::unordered_map<CGitHash,std::unordered_set<CGitHash>>&);bool ShouldShowFilter(GitRevLoglist*,const std::unordered_map<CGitHash,std::unordered_set<CGitHash>>&,const MAP_HASH_NAME&);
 void walk(std::vector<GitRevLoglist>& rows,const MAP_HASH_NAME& hashMap,const std::unordered_map<CGitHash,RollUpState>& rollUpStates,bool first){
 std::unordered_map<CGitHash,std::unordered_set<CGitHash>>commitChildren;
 std::unordered_set<CGitHash>collapsedNodes,expandedNodes;Lanes lanes;
 for(auto& row:rows){auto pRev=&row;
 if(m_ShowFilter&FILTERSHOW_MERGEPOINTS)for(auto&parent:row.m_ParentHash)commitChildren[parent].insert(row.m_CommitHash);
'''+forced+searchFilter+'''
 updateLanes(row,lanes,row.m_CommitHash,first);
 std::cout<<visible<<","<<row.m_RolledUp<<","<<row.m_RolledUpIsForced<<";";
 for(auto t:row.m_Lanes)std::cout<<int(t)<<",";
 std::cout<<";"<<lanes.activeLane<<"\\n";
 }}};
'''
main='''
int main(){CGitLogListBase c;int first;std::string head,overrides;c.m_HeadHash=CGitHash("0");std::cin>>c.m_ShowFilter>>c.m_ShowRefMask>>first>>head>>overrides;c.m_HeadHash=CGitHash(head);std::string line;std::getline(std::cin,line);std::unordered_map<CGitHash,CGitLogListBase::RollUpState>forced;
 if(overrides!="-"){std::istringstream s(overrides);std::string item;while(std::getline(s,item,',')){auto p=item.find(':');forced[CGitHash(item.substr(0,p))]=item.substr(p+1)=="C"?CGitLogListBase::RollUpState::Collapse:CGitLogListBase::RollUpState::Expand;}}
 std::vector<GitRevLoglist>rows;MAP_HASH_NAME refs;
 while(std::getline(std::cin,line)){std::istringstream s(line);std::string hash,parents,names;int boundary,matches;s>>hash>>parents>>names>>boundary>>matches;GitRevLoglist r;r.boundary=boundary;r.matches=matches;r.m_CommitHash=CGitHash(hash);if(parents!="-"){std::istringstream p(parents);std::string h;while(std::getline(p,h,','))r.m_ParentHash.emplace_back(h);}if(names!="-"){std::istringstream p(names);std::string h;while(std::getline(p,h,','))refs[r.m_CommitHash].push_back(h);}rows.push_back(r);}c.walk(rows,refs,forced,first);
}
'''
rng=random.Random(7338078);fixtures=[]
shapes=[[[1],[2],[]],[[1,2],[3],[3],[]],[[1,2,3],[],[],[],[]],[[1,2],[3,4],[4,3],[5],[5],[]]]
for _ in range(20):
 size=rng.randint(5,24);shapes.append([rng.sample(list(range(i+1,size)),rng.randint(0,min(3,size-i-1))) for i in range(size)])
for shapeIndex,parents in enumerate(shapes):
 refs=[[] for _ in parents]
 kinds=['refs/heads/','refs/remotes/','refs/tags/','refs/stash','refs/bisect/','refs/notes/','refs/custom/']
 for i in range(1,len(parents)):
  if rng.randrange(3)==0:refs[i]=[rng.choice(kinds)+str(i)]
 refs[-1]=['refs/tags/root']
 for search in ['all','alternating','none']:
  for mode,flags in [('all',7),('compressed',3),('labeled',1)]:
   for mask in [63,5,0]:
    for overrides in [{},{'0':'collapse'},{'0':'expand','1':'collapse'}]:
     fixtures.append({'name':str(shapeIndex)+'-'+mode+'-'+str(mask)+'-'+str(len(overrides))+'-'+search,'mode':mode,'mask':mask,'firstParent':shapeIndex%3==0,'overrides':overrides,'rows':[{'hash':str(i),'parents':list(map(str,p)),'refs':refs[i],'head':i==0,'matches':search=='all' or search=='alternating' and i%2==0,'boundary':shapeIndex%2==1 and i>=len(parents)-2} for i,p in enumerate(parents)],'flags':flags})
with tempfile.TemporaryDirectory(prefix='turtlegit-history-projection-') as temporary:
 directory=Path(temporary)
 (directory/'lanes.h').write_text(adapter+'\n#define private public\n'+header+'\n#undef private\n')
 (directory/'lanes.cpp').write_text(implementation)
 (directory/'oracle.cpp').write_text('#include "lanes.h"\n'+record+update+controller+filters+main)
 oracle=directory/'oracle';subprocess.run(['xcrun','clang++','-std=c++17',str(directory/'lanes.cpp'),str(directory/'oracle.cpp'),'-o',str(oracle)],check=True)
 for f in fixtures:
  overrides=','.join(h+(':'+('C' if v=='collapse' else 'E')) for h,v in f['overrides'].items()) or '-'
  payload=str(f['flags'])+' '+str(f['mask'])+' '+str(int(f['firstParent']))+' 0 '+overrides+'\n'
  payload+=''.join(r['hash']+' '+(','.join(r['parents']) or '-')+' '+(','.join(r['refs']) or '-')+' '+str(int(r['boundary']))+' '+str(int(r['matches']))+'\n' for r in f['rows'])
  lines=subprocess.check_output([str(oracle)],input=payload,text=True).splitlines()
  f['expected']=[{'visible':line.split(';')[0].split(',')[0]=='1','collapsed':line.split(';')[0].split(',')[1]=='1','forced':line.split(';')[0].split(',')[2]=='1','lanes':list(map(int,line.split(';')[1].strip(',').split(','))),'column':int(line.split(';')[2])} for line in lines]
 snapshot=directory/'fixtures.json';snapshot.write_text(json.dumps(fixtures))
 products=root/'build/Build/Products/Debug';receiver=directory/'history-projection-receiver'
 subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5','-I',str(products),'-F',str(products),str(root/'docs/qa/history-projection-native-2026-10-09.swift'),'-framework','TurtleGitCore','-o',str(receiver)],check=True)
 environment=os.environ.copy();environment['DYLD_FRAMEWORK_PATH']=str(products)
 subprocess.run([str(receiver),str(snapshot)],env=environment,check=True)
 print('Fixture SHA:',hashlib.sha256(snapshot.read_bytes()).hexdigest())
 print('Pinned source SHA:',{p:hashlib.sha256((upstream/p).read_bytes()).hexdigest() for p in ['src/TortoiseProc/GitLogListBase.cpp','src/TortoiseProc/lanes.cpp','src/TortoiseProc/lanes.h','src/TortoiseProc/LogDataVector.cpp']})
