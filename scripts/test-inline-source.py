#!/usr/bin/env python3
"""Check inline matching against the pinned, UTF-16-adapted SVNLineDiff.cpp.

Only Windows types/classification are adapted; parser, hashes and callbacks are
compiled from the original GPL source. ASCII word corpus; Unicode char corpus.
"""
import csv
import hashlib
import itertools
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import urllib.request

root = Path(__file__).resolve().parent.parent
pin = json.loads((root / 'docs/upstream.json').read_text())['commit']
with (root / 'docs/upstream-files.csv').open(newline='') as f:
    blobs = {r['path']: r['blob'] for r in csv.DictReader(f)}

def source(path):
    local = root / '.upstream/TortoiseGit'
    cache = root / 'build/qa/inline-source-cache' / pin / Path(path).name
    if (local / '.git').exists():
        data = subprocess.check_output(['git', '-C', str(local), 'show', pin + ':' + path])
    elif cache.exists():
        data = cache.read_bytes()
    else:
        with urllib.request.urlopen('https://raw.githubusercontent.com/TortoiseGit/TortoiseGit/' + pin + '/' + path, timeout=30) as f:
            data = f.read()
    assert hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest() == blobs[path], path
    cache.parent.mkdir(parents=True, exist_ok=True); cache.write_bytes(data)
    return data.decode('utf-8-sig').replace('\r\n', '\n')

def adapt(text):
    return text.replace('std::wstring', 'std::u16string').replace('wchar_t', 'char16_t').replace('WCHAR', 'char16_t')

with tempfile.TemporaryDirectory(prefix='turtlegit-inline-source-') as temporary:
    folder = Path(temporary)
    header = source('src/TortoiseMerge/svninclude/SVNLineDiff.h').replace('#include "diff.h"', '')
    body = source('src/TortoiseMerge/libsvn_diff/SVNLineDiff.cpp')
    body = body[:body.index('bool SVNLineDiff::ShowInlineDiff(')]
    body = body.replace('#include "stdafx.h"', '').replace('#include "SVNLineDiff.h"', '')
    prelude = '''#include <string>
#include <vector>
#include <iostream>
#include <cstdlib>
#include <svn_diff.h>
#include <svn_pools.h>
using LPCWSTR = const char16_t*;
static bool IsCharAlphaNumeric(char16_t c) { return (c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9'); }
static size_t _tcslen(LPCWSTR p) { return std::char_traits<char16_t>::length(p); }
static int _tcscmp(LPCWSTR a,LPCWSTR b) { while(*a && *a==*b) { ++a; ++b; } return *a<*b?-1:*a>*b?1:0; }
'''
    # Read UTF-16 code units as hex, bypassing host wchar_t and locale/encoding.
    main = r'''
static svn_error_t* emit(void* baton, apr_off_t a,apr_off_t n,apr_off_t b,apr_off_t m,apr_off_t,apr_off_t) {
 auto& out=*static_cast<std::string*>(baton); if(!out.empty()) out+=",";
 out+="["+std::to_string(a)+","+std::to_string(n)+","+std::to_string(b)+","+std::to_string(m)+"]"; return SVN_NO_ERROR;
}
static std::u16string decode(const std::string& s) { std::u16string r; for(size_t i=0;i<s.size();i+=4) r+=char16_t(std::stoul(s.substr(i,4),nullptr,16)); return r; }
int main() {
 if(apr_initialize()) return 2;
 int word; std::string x,y;
 while(std::cin>>word>>x>>y) {
  auto a=decode(x),b=decode(y); SVNLineDiff owner; svn_diff_t* diff=nullptr;
  if(!owner.Diff(&diff,a.data(),a.size(),b.data(),b.size(),word)) return 3;
  std::string common,modified; svn_diff_output_fns_t functions={};
  functions.output_common=emit;
  if(auto e=svn_diff_output2(diff,&common,&functions,nullptr,nullptr)) {svn_error_clear(e);return 4;}
  functions.output_common=nullptr; functions.output_diff_modified=emit;
  if(auto e=svn_diff_output2(diff,&modified,&functions,nullptr,nullptr)) {svn_error_clear(e);return 5;}
  std::cout<<"{\"common\":["<<common<<"],\"modified\":["<<modified<<"],\"tokens\":[";
  for(int side=0;side<2;++side) { if(side)std::cout<<","; std::cout<<"["; auto& t=side?owner.m_line2tokens:owner.m_line1tokens; for(size_t i=0;i<t.size();++i){if(i)std::cout<<",";std::cout<<t[i].size();} std::cout<<"]"; }
  std::cout<<"]}"<<std::endl;
 }
}
'''
    cpp = folder / 'reference.cpp'; cpp.write_text(prelude + adapt(header) + adapt(body) + main)
    runtime = root / 'build/git-runtime/Git/libexec/git-svn-runtime' / platform.machine()
    svn = runtime / 'Subversion'; apr = runtime / 'Dependencies'
    exe = folder / 'reference'
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-I' + str(svn / 'include/subversion-1'), '-I' + str(apr / 'include/apr-1'), str(cpp), str(svn / 'lib/libsvn_diff-1.0.dylib'), str(svn / 'lib/libsvn_subr-1.0.dylib'), str(apr / 'lib/libapr-1.0.dylib'), '-Wl,-rpath,' + str(svn / 'lib'), '-Wl,-rpath,' + str(apr / 'lib'), '-o', str(exe)], check=True)
    cases = []
    # Repeated, crossed and unequal runs exercise LCS tie choices in both modes.
    corpus = [''.join(p) for n in range(1,5) for p in itertools.product('ab', repeat=n)]
    for word in [False, True]:
        for a in corpus:
            for b in corpus:
                if word:
                    atext, btext = 'keep '+ ' '.join(a)+' shared tail', 'keep '+' '.join(b)+' shared tail'
                else:
                    atext, btext = 'keep '+a+' shared tail', 'keep '+b+' shared tail'
                cases.append(dict(base=atext, destination=btext, word=word))
    for a,b in [('🐢 café e\u0301 aba shared tail','🐢 cafe é baa shared tail'),('keep a\0b shared','keep b\0a shared'),('keep\t  x!! shared tail','keep \tx!? shared tail')]:
        cases.append(dict(base=a,destination=b,word=False))
    def hex16(s):
        data=s.encode('utf-16-le'); return ''.join(f'{int.from_bytes(data[i:i+2],"little"):04x}' for i in range(0,len(data),2))
    feed=''.join(f'{int(c["word"])} {hex16(c["base"])} {hex16(c["destination"])}\n' for c in cases)
    result=subprocess.run([str(exe)], input=feed, text=True, capture_output=True, check=True)
    lines=result.stdout.splitlines(); assert len(lines)==len(cases)
    for case,line in zip(cases,lines): case.update(json.loads(line))
    snapshot=root / 'build/qa/inline-source-expected.json'; snapshot.parent.mkdir(parents=True,exist_ok=True)
    snapshot.write_text(json.dumps(cases))
    env=os.environ.copy(); env.update(TURTLEGIT_CORE_ONLY='1',TURTLEGIT_INLINE_SOURCE_EXPECTED=str(snapshot))
    subprocess.run(['swift','test','--filter','MergeInlineComparisonTests'],cwd=root,env=env,check=True)
    print(f'PASS: pinned SVNLineDiff parser/hash/callback oracle: {len(cases)} line pairs; original source blob identities verified.',flush=True)
