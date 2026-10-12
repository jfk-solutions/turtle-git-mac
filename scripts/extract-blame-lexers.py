#!/usr/bin/env python3
"""Extract pinned Blame lexer selections, word lists and style colors without changing them."""
import ast,hashlib,json,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
source=ROOT/'.upstream/TortoiseGit/src/TortoiseGitBlame/TortoiseGitBlameView.cpp'
text=source.read_text(encoding='utf-8-sig')
setup=text.split('void CTortoiseGitBlameView::SetupLexer(CString filename)',1)[1].split('int CTortoiseGitBlameView::GetEncode',1)[0]
constants={name:tuple(int(x,0) for x in values.split(',')) for name,values in re.findall(r'const COLORREF (\w+) = RGB\(([^)]+)\)',(source.with_suffix('.h')).read_text())}
styles={name:int(value) for name,value in re.findall(r'#define (SCE_\w+) (\d+)',(ROOT/'.upstream/TortoiseGit/ext/lexilla/include/SciLexer.h').read_text())}
def rgb(value):
 value=value.strip()
 return list(constants[value]) if value in constants else [int(x.strip(),0) for x in re.fullmatch(r'RGB\(([^)]+)\)',value)[1].split(',')]
def palette(block):
 result={}
 for style,fore,back in re.findall(r'SetAStyle\((SCE_\w+),\s*(RGB\([^)]+\)|\w+)(?:,\s*(RGB\([^)]+\)|\w+))?\)',block):
  result[str(styles[style])]={'foreground':rgb(fore)}
  if back:result[str(styles[style])]['background']=rgb(back)
 for style in re.findall(r'SendEditor\(SCI_STYLESETBOLD,\s*(SCE_\w+),\s*1\)',block):result.setdefault(str(styles[style]),{})['bold']=True
 return result
cpp=palette(setup.split('void CTortoiseGitBlameView::SetupCppLexer()',1)[1])
configurations=[]
for block in re.split(r'(?=\t\tif \()',setup.split('void CTortoiseGitBlameView::SetupCppLexer()',1)[0]):
 block=block.split('\n\t}\n\telse\n',1)[0]
 extensions=re.findall(r'wcscmp\(line, L"([^"]+)"\)',block)
 if not extensions:continue
 lexer=re.search(r'CreateLexer\("([^"]+)"\)',block)[1]
 wordlists={}
 for index,literal in re.findall(r'SCI_SETKEYWORDS, (\d+),.*?L"((?:\\.|[^"\\])*)"',block,re.S):
  literal=literal.replace('\\\n','')
  wordlists[index]=ast.literal_eval('"'+literal+'"')
 if lexer=='hypertext':
  html=palette(block)
  for first,last,color in [('SCE_HB_DEFAULT','SCE_HB_STRINGEOL',constants['lightBlue']),('SCE_HBA_DEFAULT','SCE_HBA_STRINGEOL',(255,255,0)),('SCE_HJ_DEFAULT','SCE_HJ_SYMBOLS',constants['offWhite']),('SCE_HJA_DEFAULT','SCE_HJA_SYMBOLS',(223,223,127))]:
   for number in range(styles[first],styles[last]+1):html.setdefault(str(number),{})['background']=list(color)
  for symbol,color in [('SCE_HB_STRINGEOL',(127,127,255)),('SCE_HBA_STRINGEOL',(207,207,127)),('SCE_HJ_STRINGEOL',(223,223,127)),('SCE_HJA_STRINGEOL',(0,175,95))]:html.setdefault(str(styles[symbol]),{})['background']=list(color)
 else:html={}
 configurations.append({'extensions':extensions,'lexer':lexer,'wordlists':wordlists,'styles':cpp if lexer in ['cpp','pascal'] else html if lexer=='hypertext' else palette(block)})
assert len(configurations)==10, len(configurations)
result={'version':1,'upstream':'7338078f8ddd924b8cddee35f512f2286072136d','lexilla':'ef08a1a00ce151ccdddf7da700fbe1a4934a9c71','source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'extension_matching':'case-sensitive; unknown extension plain; no extension cpp without keyword lists','configurations':configurations,'no_extension':{'extensions':[],'lexer':'cpp','wordlists':{},'styles':cpp}}
output=ROOT/'Configuration/BlameLexers.json';output.write_text(json.dumps(result,indent=2)+'\n');print(output)
