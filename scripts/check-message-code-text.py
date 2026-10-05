#!/usr/bin/env python3
"""Differential check against the pinned upstream encoding detector; needs its checkout."""
import hashlib
import pathlib
import random
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
source = root / '.upstream/TortoiseGit/src/TortoiseMerge/FileTextLines.cpp'
expected = 'e9ac66ef889687750921f09d4ccafce7f843e996'
raw = source.read_bytes()
assert hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest() == expected
text = raw.decode('utf-8-sig')
start = text.index('CFileTextLines::UnicodeType CFileTextLines::CheckUnicodeType(')
end = text.index('\nBOOL CFileTextLines::Load(', start)
body = text[start:end]
prefix = r'''
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>
using LPCVOID = const void*;
using UINT8 = uint8_t; using UINT16 = uint16_t; using UINT32 = uint32_t; using DWORD = uint32_t;
static bool useUTF8;
static int CRegDWORD(const wchar_t*, bool) { return useUTF8; }
#define FALSE false
class CFileTextLines { public:
enum class UnicodeType { AUTOTYPE, BINARY, ASCII, UTF16_LE, UTF16_BE, UTF16_LEBOM, UTF16_BEBOM, UTF32_LE, UTF32_BE, UTF8, UTF8BOM };
static UnicodeType CheckUnicodeType(LPCVOID, int);
};
'''
suffix = r'''
int main() {
 const char* names[] = {"auto", "binary", "ascii", "utf16LE", "utf16BE", "utf16LEBOM", "utf16BEBOM", "utf32LE", "utf32BE", "utf8", "utf8BOM"};
 std::string line;
 while (std::getline(std::cin, line)) {
  useUTF8 = line[0] == '1'; std::vector<uint8_t> bytes;
  for (size_t i=2; i<line.size(); i+=2) bytes.push_back(std::stoul(line.substr(i,2), nullptr, 16));
  std::cout << names[static_cast<int>(CFileTextLines::CheckUnicodeType(bytes.data(), bytes.size()))] << '\n';
 }
}
'''
driver = r'''
import Foundation
let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
for line in input.split(separator: "\n") {
 let chars = Array(line.utf8), flag = chars[0] == 49
 let bytes = stride(from: 2, to: chars.count, by: 2).map { UInt8(String(decoding: chars[$0..<($0+2)], as: UTF8.self), radix: 16)! }
 print(MessageCodeText.detect(Data(bytes), useUTF8: flag))
}
'''
rng = random.Random(0x54474954)
cases = [b'', b'\0', b'A\0', b'plain', '雪🦎'.encode()]
boms = [b'\xff\xfe', b'\xfe\xff', b'\xff\xfe\0\0', b'\0\0\xfe\xff', b'\xef\xbb\xbf']
for index in range(6000):
    size = rng.randrange(257)
    data = bytearray(rng.randbytes(size))
    if index % 4 == 0:
        data = bytearray(boms[index % len(boms)]) + data
    elif index % 4 == 1:
        data = bytearray(rng.choice([65, 66, 0]) for _ in range(size))
    elif index % 4 == 2:
        data = bytearray(rng.choice([b'\xe0\x80\x80', b'\xed\xa0\x80', b'\xc2', b'\xf4\x90\x80\x80'])) + data
    cases.append(bytes(data))
payload = ''.join(f'{flag} {data.hex()}\n' for data in cases for flag in (0, 1)).encode()
with tempfile.TemporaryDirectory(prefix='TurtleGitCodeTextOracle-') as folder:
    folder = pathlib.Path(folder)
    (folder / 'oracle.cpp').write_text(prefix + body + suffix)
    (folder / 'main.swift').write_text(driver)
    subprocess.run(['xcrun', 'clang++', '-std=c++17', str(folder / 'oracle.cpp'), '-o', str(folder / 'oracle')], check=True)
    subprocess.run(['xcrun', 'swiftc', str(root / 'Sources/TurtleGitCore/MessageCodeText.swift'), str(folder / 'main.swift'), '-o', str(folder / 'native')], check=True)
    upstream = subprocess.check_output([str(folder / 'oracle')], input=payload).splitlines()
    native = subprocess.check_output([str(folder / 'native')], input=payload).splitlines()
    assert len(upstream) == len(native) == len(cases) * 2
    failures = [i for i, pair in enumerate(zip(upstream, native)) if pair[0] != pair[1]]
    assert not failures, [(i, upstream[i], native[i]) for i in failures[:10]]
print(f'{len(upstream)} detector comparisons passed; upstream blob {expected}; corpus sha256 {hashlib.sha256(payload).hexdigest()}')
