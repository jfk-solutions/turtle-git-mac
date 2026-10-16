#!/usr/bin/env python3
"""Build pinned MovedBlocks.cpp with platform types adapted; emit a source oracle."""
import csv
import hashlib
import json
from pathlib import Path
import random
import subprocess
import tempfile
import urllib.request
root=Path(__file__).resolve().parent.parent
pin=json.loads((root/'docs/upstream.json').read_text())['commit']
path='src/TortoiseMerge/MovedBlocks.cpp'
with (root/'docs/upstream-files.csv').open(newline='') as f: blob=next(r['blob'] for r in csv.DictReader(f) if r['path']==path)
cache=root/'build/qa/moved-source-cache'/pin/'MovedBlocks.cpp'
local=root/'.upstream/TortoiseGit'
if (local/'.git').exists(): data=subprocess.check_output(['git','-C',str(local),'show',pin+':'+path])
elif cache.exists(): data=cache.read_bytes()
else:
    with urllib.request.urlopen('https://raw.githubusercontent.com/TortoiseGit/TortoiseGit/'+pin+'/'+path,timeout=30) as f:data=f.read()
assert hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()==blob
cache.parent.mkdir(parents=True,exist_ok=True);cache.write_bytes(data)
body='\n'.join(line for line in data.decode('utf-8-sig').splitlines() if not line.startswith('#include'))
body=body.replace('__super::find','std::map<CString, EquivalencyGroup*>::find')
prelude=r'''
#include <set>
#include <map>
#include <string>
#include <vector>
#include <iostream>
#include <cstring>
#include <cstdlib>
#include <algorithm>
using LONG=int;
using apr_off_t=long long;
struct apr_pool_t {std::vector<void*> allocations; ~apr_pool_t(){for(auto p:allocations)free(p);}};
void* apr_palloc(apr_pool_t* pool,size_t n){auto p=malloc(n);pool->allocations.push_back(p);return p;}
struct CString:std::string {
 using std::string::string;
 CString(const std::string& s):std::string(s){}
 void Remove(char c){erase(std::remove(begin(),end(),c),end());}
 CString& TrimLeft(const wchar_t*){erase(0,find_first_not_of(" \t"));return *this;}
 CString& TrimRight(const wchar_t*){erase(find_last_not_of(" \t")+1);return *this;}
};
enum class IgnoreWS{None,WhiteSpaces,AllWhiteSpaces};
enum {svn_diff__type_diff_modified=1};
struct svn_diff_t {int type;apr_off_t original_start,original_length,modified_start,modified_length;svn_diff_t* next;};
struct tsvn_svn_diff_t_extension {svn_diff_t* base;tsvn_svn_diff_t_extension* next;int moved_from,moved_to;};
struct Lines {std::vector<CString> data;int GetCount()const{return data.size();}const CString& GetAt(int n)const{return data.at(n);}};
struct CDiffData {Lines m_arBaseFile,m_arYourFile;tsvn_svn_diff_t_extension* MovedBlocksDetect(svn_diff_t*,IgnoreWS,apr_pool_t*);};
'''
main=r'''
std::string unhex(const std::string& s){if(s=="-")return "";std::string r;for(size_t i=0;i<s.size();i+=2)r+=char(std::stoul(s.substr(i,2),nullptr,16));return r;}
int main(){int ws,n,m,k;while(std::cin>>ws>>n>>m>>k){apr_pool_t pool;CDiffData owner;std::string s;for(int i=0;i<n;++i){std::cin>>s;owner.m_arBaseFile.data.emplace_back(unhex(s));}for(int i=0;i<m;++i){std::cin>>s;owner.m_arYourFile.data.emplace_back(unhex(s));}
 svn_diff_t* head=nullptr;svn_diff_t* tail=nullptr;
 for(int i=0;i<k;++i){auto p=static_cast<svn_diff_t*>(apr_palloc(&pool,sizeof(svn_diff_t)));memset(p,0,sizeof(*p));p->type=svn_diff__type_diff_modified;std::cin>>p->original_start>>p->original_length>>p->modified_start>>p->modified_length;if(tail)tail->next=p;else head=p;tail=p;}
 auto ext=owner.MovedBlocksDetect(head,static_cast<IgnoreWS>(ws),&pool);std::map<int,int> links;
 for(;ext;ext=ext->next){auto p=ext->base;if(ext->moved_to>=0)for(int i=0;i<p->original_length;++i)links[p->original_start+i]=ext->moved_to+i;if(ext->moved_from>=0)for(int i=0;i<p->modified_length;++i)links[ext->moved_from+i]=p->modified_start+i;}
 std::cout<<"[";bool first=true;for(auto [a,b]:links){if(!first)std::cout<<",";first=false;std::cout<<"["<<a<<","<<b<<"]";}std::cout<<"]"<<std::endl;
}}
'''
rng=random.Random(7338078)
cases=[]
# Raw modified intervals from disjoint source regions; vary repeats, partial
# blocks, crossed unique seeds, whitespace normalization and final NoEnding.
for _ in range(420):
    a=[rng.choice(['a','b','c','unique-'+str(i),'🐢 雪',' e\u0301 ',' é ','\tq ',' q\t']) for i in range(rng.randrange(2,18))]
    b=a[:];rng.shuffle(b)
    a+=['tail'];b+=['tail']
    cut=rng.randrange(1,len(a));cutb=rng.randrange(1,len(b))
    segments=[[0,cut,0,cutb],[cut,len(a)-1-cut,cutb,len(b)-1-cutb]]
    # Adjacent segments remain separate because the source mutates each block.
    for ws in range(3):cases.append(dict(base=a,mine=b,segments=segments,whitespace=ws,ended=True))
# Source's final unended-record refusal, and a real cut/paste with intervening
# unchanged rows excluded from the equivalence groups.
for ended in [False,True]:
    cases.append(dict(base=['keep','move','tail'],mine=['move','keep','tail'],segments=[[0,2,0,2]],whitespace=0,ended=ended))
    cases.append(dict(base=['keep','move'],mine=['move','keep'],segments=[[0,2,0,2]],whitespace=0,ended=ended))
cases.append(dict(base=['head','moved','x','same','same2','x','tail'],mine=['head','same','same2','moved','x','x','tail'],segments=[[1,2,1,0],[5,0,3,2]],whitespace=0,ended=True))
with tempfile.TemporaryDirectory(prefix='turtlegit-moved-source-') as temporary:
    folder=Path(temporary);cpp=folder/'reference.cpp';cpp.write_text(prelude+body+main);exe=folder/'reference'
    subprocess.run(['xcrun','clang++','-std=c++17',str(cpp),'-o',str(exe)],check=True)
    feed=[]
    for c in cases:
        a=c['base']+([''] if c['ended'] else []);b=c['mine']+([''] if c['ended'] else [])
        feed.append(f"{c['whitespace']} {len(a)} {len(b)} {len(c['segments'])}")
        feed.extend(s.encode().hex() or '-' for s in a+b)
        feed.extend(' '.join(map(str,segment)) for segment in c['segments'])
    result=subprocess.run([str(exe)],input='\n'.join(feed)+'\n',text=True,capture_output=True,check=True,timeout=60)
    lines=result.stdout.splitlines();assert len(lines)==len(cases)
    for c,line in zip(cases,lines):c['links']=[p for p in json.loads(line) if p[0]<len(c['base']) and p[1]<len(c['mine'])]
    output=root/'build/qa/moved-block-source-expected.json';output.write_text(json.dumps(cases,ensure_ascii=False))
    print(f'Pinned MovedBlocks.cpp oracle: {len(cases)} cases; source blob {blob}; {output}')
