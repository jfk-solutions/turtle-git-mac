#!/usr/bin/env python3
"""Compare Core scope arguments with the pinned GetLogCmd filter body.

CTime supplies injected local-midnight epochs; this does not test Windows time APIs.
"""
import hashlib
import itertools
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
pin = json.loads((root / 'docs/upstream.json').read_text())['commit']
source = subprocess.check_output(['git', '-C', str(root / '.upstream/TortoiseGit'), 'show', pin + ':src/Git/Git.cpp']).decode().replace('\r\n', '\n')
start = source.index('\tif (Filter)\n', source.index('CGit::GetLogCmd'))
end = source.index('\n\tif (logOrderBy', start)
body = source[start:end]
assert 'static_cast<DWORD>(time.GetTime())' in body and '--min-age={}' in body
header = r'''
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>
using DWORD = uint32_t;
using __time64_t = int64_t;
using CString = std::string;
int64_t midnight;
struct CTime {
    CTime() = default;
    CTime(int,int,int,int,int,int) {}
    static CTime GetCurrentTime() { return CTime(); }
    int GetYear() const { return 0; }
    int GetMonth() const { return 0; }
    int GetDay() const { return 0; }
    int64_t GetTime() const { return midnight; }
};
namespace std {
    template<class T> string format(string value, T number) { return value.replace(value.find("{}"), 2, to_string(number)); }
}
struct CFilterData {
    enum { SHOW_NO_LIMIT, SHOW_LAST_SEL_DATE, SHOW_LAST_N_COMMITS, SHOW_LAST_N_YEARS, SHOW_LAST_N_MONTHS, SHOW_LAST_N_WEEKS };
    int m_NumberOfLogsScale;
    DWORD m_NumberOfLogs;
    int64_t m_From, m_To;
};
int main() {
    CFilterData data;
    while (std::cin >> data.m_NumberOfLogsScale >> data.m_NumberOfLogs >> midnight >> data.m_From >> data.m_To) {
        auto Filter = &data;
        std::vector<std::string> params;
'''
footer = r'''
        for (size_t i = 0; i < params.size(); ++i) { if(i) std::cout << '\t'; std::cout << params[i]; }
        std::cout << '\n';
    }
}
'''
cases = [dict(zip(['scale', 'number', 'midnight', 'from', 'until'], values)) for values in itertools.product(range(6), [0,1,2,10,2147483647,4294967295], [-86400,0,20000*86400,49710*86400,49711*86400], [-1,0,1,1700000000], [-1,0,1800000000])]
products = root / 'build/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='turtlegit-history-limit-oracle-') as temporary:
    directory = Path(temporary)
    cpp = directory / 'source.cpp'; cpp.write_text(header + body + footer)
    oracle = directory / 'source-oracle'
    subprocess.run(['xcrun', 'clang++', '-std=c++17', str(cpp), '-o', str(oracle)], check=True)
    records = '\n'.join(' '.join(str(item[k]) for k in ['scale','number','midnight','from','until']) for item in cases) + '\n'
    expected = [line.split('\t') if line else [] for line in subprocess.check_output([str(oracle)], input=records.encode()).decode().splitlines()]
    receiver = directory / 'scope-oracle'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products), str(root / 'docs/qa/log-history-limits-oracle-2026-10-09.swift'), '-framework', 'TurtleGitCore', '-o', str(receiver)], check=True)
    fixture = directory / 'cases.json'; fixture.write_text(json.dumps(cases))
    environment = os.environ.copy(); environment['DYLD_FRAMEWORK_PATH'] = str(products)
    actual = json.loads(subprocess.check_output([str(receiver), str(fixture)], env=environment))
    assert len(actual) == len(expected) == len(cases)
    for item, left, right in zip(cases, actual, expected):
        assert left == right, (item, left, right)
    print('PASS: ' + str(len(cases)) + ' scopes match verbatim pinned GetLogCmd filter body; zero/max DWORD counts, absent/zero/positive From/To, negative/zero/current/DWORD-wrap midnight; injected CTime only')
    print('Fixture SHA256: ' + hashlib.sha256(fixture.read_bytes()).hexdigest())
