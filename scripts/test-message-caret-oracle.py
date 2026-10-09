#!/usr/bin/env python3
"""Compare Swift caret coordinates with the unchanged pinned Scintilla Document."""
from pathlib import Path
import itertools
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
upstream = root / '.upstream/TortoiseGit'
pin = '7338078f8ddd924b8cddee35f512f2286072136d'
assert subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip() == pin
src = upstream / 'ext/scintilla/src'
names = ['Document', 'CellBuffer', 'PerLine', 'CharClassify', 'CharacterCategoryMap', 'Decoration', 'CaseFolder', 'CaseConvert', 'RESearch', 'UniConversion', 'RunStyles', 'UndoHistory', 'ChangeHistory']
for name in names:
    relative = 'ext/scintilla/src/' + name + '.cxx'
    assert (src / (name + '.cxx')).read_bytes() == subprocess.check_output(['git', '-C', str(upstream), 'show', pin + ':' + relative])
cases = []
for tokens in itertools.product(['a', '\t', '\r', '\n', '雪', 'e\u0301', '😀', '👩‍💻', '\u2028'], repeat=3):
    value = ''.join(tokens)
    for count in range(len(value) + 1):
        prefix = value[:count]
        cases.append((value, len(prefix.encode('utf-16-le')) // 2, len(prefix.encode('utf-8'))))
cases.append(('', 0, 0))
payload = ''.join((value.encode().hex() or '-') + ' ' + str(offset) + ' ' + str(byte) + '\n' for value, offset, byte in cases)
with tempfile.TemporaryDirectory(prefix='turtlegit-caret-oracle-') as temporary:
    task = Path(temporary)
    # Same header prerequisites as upstream Document.cxx. Only platform diagnostic
    # functions are supplied locally; assertions abort, never silently pass.
    headers = (src / 'Document.cxx').read_text().split('using namespace Scintilla;')[0]
    cpp = task / 'oracle.cxx'
    cpp.write_text(headers + r'''
#include <iostream>
#include <sstream>
using namespace Scintilla;
using namespace Scintilla::Internal;
namespace Scintilla::Internal::Platform {
void DebugDisplay(const char *s) noexcept { std::cerr << s; }
void DebugPrintf(const char *, ...) noexcept {}
bool ShowAssertionPopUps(bool value) noexcept { return value; }
void Assert(const char *c, const char *file, int line) noexcept { std::cerr << file << ":" << line << ":" << c; std::abort(); }
}
int main() {
 std::string row;
 while (std::getline(std::cin, row)) {
  std::istringstream input(row); std::string hex; long offset, byte; input >> hex >> offset >> byte;
  std::string text;
  if (hex != "-") for (size_t i = 0; i < hex.size(); i += 2) text.push_back(static_cast<char>(std::stoi(hex.substr(i, 2), nullptr, 16)));
  Document document(DocumentOption::Default); document.InsertString(0, text);
  std::cout << document.SciLineFromPosition(byte) + 1 << "/" << document.GetColumn(byte) + 1 << "\n";
 }
}
''')
    binary = task / 'oracle'
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-O1', '-DNO_CXX11_REGEX', '-I', str(src), '-I', str(upstream / 'ext/scintilla/include'), str(cpp), *[str(src / (name + '.cxx')) for name in names], '-o', str(binary)], check=True)
    swift = task / 'main.swift'
    swift.write_text('''import Foundation
while let row = readLine() {
 let fields = row.split(separator: " "); let hex = String(fields[0])
 var bytes: [UInt8] = []
 if hex != "-" { var index = hex.startIndex; while index < hex.endIndex { let next = hex.index(index, offsetBy: 2); bytes.append(UInt8(hex[index..<next], radix: 16)!); index = next } }
 let text = String(decoding: bytes, as: UTF8.self)
 print(MessageCaretPosition.at(text, utf16Offset: Int(fields[1])!).text)
}
''')
    native = task / 'swift-caret'
    subprocess.run(['xcrun', 'swiftc', str(root / 'Sources/TurtleGitCore/MessageCaretPosition.swift'), str(swift), '-o', str(native)], check=True)
    expected = subprocess.check_output([str(binary)], input=payload, text=True).splitlines()
    actual = subprocess.check_output([str(native)], input=payload, text=True).splitlines()
    assert len(expected) == len(actual) == len(cases)
    for case, left, right in zip(cases, expected, actual): assert left == right, (case, left, right)
    print(f'PASS: {len(cases)} scalar-boundary caret positions match unchanged pinned Scintilla Document line/column, including CR/LF/CRLF, eight-column tabs, combining marks, emoji and default Unicode line-end mode. No physical selection/Windows rendering claim.')
