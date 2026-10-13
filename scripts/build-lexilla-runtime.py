#!/usr/bin/env python3
"""Build pinned Lexilla engines as a universal, read-only macOS helper."""
import hashlib,json,shutil,subprocess,tarfile,urllib.request
from pathlib import Path
from pinned_download import download_verified

ROOT=Path(__file__).resolve().parents[1]
pin=json.loads((ROOT/'Configuration/LexillaRuntime.json').read_text())
target=ROOT/'build/lexilla-runtime/Lexilla'
if target.exists() and not (target/'provenance.json').exists():raise RuntimeError('Unrecognized Lexilla output directory')
cache=ROOT/'build/lexilla-runtime/cache';cache.mkdir(parents=True,exist_ok=True)
archive=cache/(pin['lexilla_commit']+'.tar.gz')
if not archive.exists():
    bundled=ROOT.parent/'lexilla.tar.gz'
    if bundled.is_file():shutil.copyfile(bundled,archive)
    else:download_verified(pin['url'],archive,pin['sha256'])
if hashlib.sha256(archive.read_bytes()).hexdigest()!=pin['sha256']:raise RuntimeError('Lexilla archive checksum mismatch')
work=ROOT/'build/lexilla-runtime/work';work.mkdir(parents=True,exist_ok=True)
with tarfile.open(archive) as source:
    for entry in source.getmembers():
        path=work.joinpath(*Path(entry.name).parts[1:])
        if not path.resolve().is_relative_to(work.resolve()):raise RuntimeError('Lexilla archive escape')
        if entry.isdir():path.mkdir(parents=True,exist_ok=True)
        elif entry.isfile():path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(source.extractfile(entry).read())
        else:raise RuntimeError('Unsupported Lexilla source entry')
for name,digest in pin['scintilla_headers'].items():
    if hashlib.sha256((ROOT/'Sources/TurtleGitLexilla/Scintilla'/name).read_bytes()).hexdigest()!=digest:raise RuntimeError('Scintilla header checksum mismatch')
target.mkdir(parents=True,exist_ok=True)
(target/'provenance.json').write_text(json.dumps({'state':'building','lexilla_commit':pin['lexilla_commit']})+'\n')
sources=[ROOT/'Sources/TurtleGitLexilla/main.cpp',*sorted((work/'lexlib').glob('*.cxx')),*[work/'lexers'/name for name in ['LexCPP.cxx','LexPython.cxx','LexPascal.cxx','LexHTML.cxx']]]
subprocess.run(['xcrun','clang++','-std=c++17','-O2','-arch','arm64','-arch','x86_64','-mmacosx-version-min=13.0',
                '-I',str(ROOT/'Sources/TurtleGitLexilla/Scintilla'),'-I',str(work/'include'),'-I',str(work/'lexlib'),
                *map(str,sources),'-o',str(target/'lexilla')],check=True)
shutil.copyfile(ROOT/'Configuration/BlameLexers.json',target/'BlameLexers.json')
shutil.copyfile(ROOT/'LICENSE',target/'LICENSE')
shutil.copyfile(work/'License.txt',target/'Lexilla-LICENSE.txt')
shutil.copyfile(ROOT/'Sources/TurtleGitLexilla/Scintilla/License.txt',target/'Scintilla-LICENSE.txt')
kit=target/'Sources'
if kit.exists():shutil.rmtree(kit)
rebuild=kit/'build';rebuild.mkdir(parents=True)
shutil.copyfile(archive,kit/'lexilla.tar.gz')
shutil.copytree(ROOT/'Sources/TurtleGitLexilla',rebuild/'Sources/TurtleGitLexilla')
for folder in ['Configuration','scripts']:(rebuild/folder).mkdir()
for name in ['LexillaRuntime.json','BlameLexers.json']:shutil.copyfile(ROOT/'Configuration'/name,rebuild/'Configuration'/name)
for name in ['build-lexilla-runtime.py','validate-lexilla-runtime.py','pinned_download.py']:shutil.copyfile(ROOT/'scripts'/name,rebuild/'scripts'/name)
shutil.copyfile(ROOT/'LICENSE',rebuild/'LICENSE')
manifest={**pin,'files':{name:hashlib.sha256((target/name).read_bytes()).hexdigest() for name in ['lexilla','BlameLexers.json','LICENSE','Lexilla-LICENSE.txt','Scintilla-LICENSE.txt']},
          'adapter_sha256':hashlib.sha256((ROOT/'Sources/TurtleGitLexilla/main.cpp').read_bytes()).hexdigest(),
          'source_archive_included':True}
(target/'provenance.json').write_text(json.dumps(manifest,indent=2)+'\n')
subprocess.run(['python3',str(ROOT/'scripts/validate-lexilla-runtime.py'),str(target)],check=True)
print(target)
