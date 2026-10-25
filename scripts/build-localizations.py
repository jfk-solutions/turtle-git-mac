#!/usr/bin/env python3
"""Build native label translations from byte-verified pinned TortoiseGit PO catalogs."""
import argparse
import ast
import csv
import hashlib
import json
from pathlib import Path
import re
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT/'Sources/TurtleGitMac/Resources/Localizable.xcstrings'
MANIFEST = ROOT/'Sources/TurtleGitMac/Resources/LocalizationManifest.json'
GENERATED = ROOT/'Sources/TurtleGitCore/AppLanguages.generated.swift'
CREDITS = ROOT/'Sources/TurtleGitMac/Resources/LocalizationCredits.txt'
LABEL_ALIASES = {'Renamed':'renamed', 'Untracked':'Unversioned', 'Skip-worktree':'skip-worktree', 'Last modified':'Modification date', 'File size':'Size'}
ALIASES = {'ca':'ca', 'sr@Cyrl':'sr', 'sr@latin':'sr-Latn', 'zh_CN':'zh-Hans', 'zh_TW':'zh-Hant', 'ta_IN':'ta'}


def parse_po(text):
    entries = []
    item = {}; field = None; fuzzy = False; plural = False
    def finish():
        if item.get('msgid') and item.get('msgstr') and not fuzzy and not plural:
            entries.append((item['msgid'], item['msgstr']))
    for line in (text + '\n\n').splitlines():
        line = line.strip()
        if not line:
            finish(); item = {}; field = None; fuzzy = False; plural = False
        elif line.startswith('#,'):
            fuzzy = fuzzy or 'fuzzy' in line[2:].split(',') or 'fuzzy' in [x.strip() for x in line[2:].split(',')]
        elif line.startswith('#'):
            continue
        elif line.startswith('msgid_plural') or line.startswith('msgstr['):
            plural = True; field = None
        elif line.startswith(('msgid ', 'msgstr ', 'msgctxt ')):
            field, quoted = line.split(' ', 1)
            item[field] = ast.literal_eval(quoted)
        elif line.startswith('"'):
            if field: item[field] += ast.literal_eval(line)
            elif not plural: raise ValueError('Unattached PO continuation')
        else:
            raise ValueError('Unsupported PO syntax: ' + line[:100])
    return entries


def label(text):
    # Windows mnemonic markers are presentation syntax. Literal && remains &.
    text = text.split('\t', 1)[0].replace('&&', '\0')
    text = re.sub(r'&(?=\S)', '', text).replace('\0', '&')
    return re.sub(r'\bTortoiseGit\b', 'TurtleGit for Mac', text).replace('\r\n', '\n')


def variants(source, translation):
    a, b = label(source), label(translation)
    result = [(a,b)]
    if '...' in a:
        value = b.replace('...', '…')
        if a.endswith('...') and not value.endswith('…'): value += '…'
        result.append((a.replace('...', '…'), value))
    if a and not a.endswith(('…','...')) and '\n' not in a:
        result.append((a+'…', b.rstrip('…')+'…'))
    if a == 'Next >': result.append(('Next',b.removesuffix(' >')))
    if a == '< Back': result.append(('Back',b.removeprefix('< ')))
    for native, canonical in LABEL_ALIASES.items():
        if a == canonical: result.append((native,b))
    return result


def count_fields(text):
    fields = re.findall(r'\{([a-z_]+)\}', text)
    remainder = re.sub(r'\{[a-z_]+\}', '', text)
    return None if '{' in remainder or '}' in remainder else fields


def validate_native_translation(key, value):
    if not value or '%' in key or '%' in value:
        raise ValueError('Native label adaptations must be nonempty and must not execute format strings')
    expected, actual = count_fields(key), count_fields(value)
    if expected is None or actual is None or sorted(expected) != sorted(actual) or len(set(expected)) != len(expected):
        raise ValueError('Native count translation changes named integer fields: ' + key)


def native_keys():
    keys = set()
    for folder in ['Sources/TurtleGitMac','Sources/TurtleGitCore','FinderSync']:
        for path in (ROOT/folder).glob('*.swift'):
            if path.name.endswith('.generated.swift'): continue
            for quoted in re.findall(r'"(?:[^"\\]|\\.)*"', path.read_text()):
                try: value = json.loads(quoted)
                except (ValueError, TypeError): continue
                if value and '%' not in value: keys.add(value)
    return keys


def verified_source(path, pin, blobs):
    checkout = ROOT/'.upstream/TortoiseGit'
    cache = ROOT/'build/translation-source'/pin/path
    if (checkout/'.git').exists(): data = subprocess.check_output(['git','-C',str(checkout),'show',pin+':'+path])
    elif cache.exists(): data = cache.read_bytes()
    else:
        with urllib.request.urlopen('https://raw.githubusercontent.com/TortoiseGit/TortoiseGit/'+pin+'/'+path,timeout=30) as stream: data = stream.read()
    digest = hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
    if digest != blobs[path]: raise ValueError('Pinned PO blob mismatch: '+path)
    cache.parent.mkdir(parents=True,exist_ok=True);cache.write_bytes(data)
    return data


def build():
    pin = json.loads((ROOT/'docs/upstream.json').read_text())['commit']
    with (ROOT/'docs/upstream-files.csv').open() as stream: blobs = {row['path']:row['blob'] for row in csv.DictReader(stream)}
    paths = sorted(path for path in blobs if re.fullmatch(r'Languages/Tortoise_.+\.po',path))
    keys = native_keys(); strings = {}; records = []; credits = []; count_templates = {}
    for path in paths:
        source_id = Path(path).stem.removeprefix('Tortoise_')
        language = ALIASES.get(source_id,source_id.replace('_','-'))
        source_text = verified_source(path,pin,blobs).decode('utf-8-sig')
        credits.append(path+'\n'+'\n'.join(source_text.splitlines()[:source_text.splitlines().index('msgid ""')]))
        candidates = {}; skipped_formats = 0
        for original, translated in parse_po(source_text):
            # C/Win32 formatting, plurals and runtime interpolation need explicit
            # native adapters, never a speculative format-string conversion.
            if '%' in original or '%' in translated or '\0' in original or '\0' in translated:
                skipped_formats += 1; continue
            if original.startswith('ID:'): continue
            for key, value in variants(original, translated):
                if key in keys: candidates.setdefault(key,set()).add(value)
        accepted = {key:next(iter(values)) for key,values in candidates.items() if len(values)==1}
        for key,value in accepted.items():
            strings.setdefault(key,{'extractionState':'manual','localizations':{}})['localizations'][language] = {'stringUnit':{'state':'translated','value':value}}
        records.append({'id':language,'source':path,'blob':blobs[path],'translated_keys':len(accepted),'ambiguous_keys_skipped':sum(len(values)>1 for values in candidates.values()),'formatted_entries_skipped':skipped_formats})
    adaptations_path = ROOT/'Configuration/NativeTranslations.json'
    adaptations = json.loads(adaptations_path.read_text())
    for language, entries in adaptations.items():
        if language not in {item['id'] for item in records}: raise ValueError('Unknown adaptation locale: '+language)
        for key,value in entries.items():
            if key not in keys: raise ValueError('Unused native translation key: '+key)
            validate_native_translation(key,value)
            if count_fields(key): count_templates[key] = count_fields(key)
            strings.setdefault(key,{'extractionState':'manual','localizations':{}})['localizations'][language] = {'stringUnit':{'state':'translated','value':value}}
    for key, entry in strings.items():
        entry['localizations']['en'] = {'stringUnit':{'state':'translated','value':key}}
    for record in records:
        record['translated_keys'] = sum(record['id'] in value['localizations'] for value in strings.values())
    payload = {'sourceLanguage':'en','strings':dict(sorted(strings.items())),'version':'1.0'}
    catalog = (json.dumps(payload,ensure_ascii=False,indent=2,sort_keys=True)+'\n').encode()
    ids = sorted(['en']+[record['id'] for record in records])
    if len(set(ids)) != len(ids): raise ValueError('Duplicate native language identifiers')
    manifest = {'schema':1,'upstream_commit':pin,'catalog_sha256':hashlib.sha256(catalog).hexdigest(),'keys':len(strings),'languages':records,'reviewed_label_aliases':LABEL_ALIASES,'reviewed_count_templates':count_templates,'native_adaptations':{'path':'Configuration/NativeTranslations.json','sha256':hashlib.sha256(adaptations_path.read_bytes()).hexdigest()},'scope':'Literal labels, reviewed spelling aliases and validated native integer-count templates. Other missing/fuzzy/ambiguous/plural/formatted/native-only text falls back to English; dynamic native menus/alerts remain under migration.'}
    generated = '// Generated by scripts/build-localizations.py from pinned PO catalogs.\n// SPDX-License-Identifier: GPL-2.0-or-later\nimport Foundation\n\npublic extension AppLanguageChoice {\n    static let bundledIDs: [String] = '+json.dumps(ids)+'\n}\n'
    credit_text = 'TurtleGit for Mac — translation notices\n\nMatching native labels adapted from TortoiseGit at '+pin+'.\nDistributed under GPL-2.0-or-later; see LICENSE and the original catalogs.\nSource: https://github.com/TortoiseGit/TortoiseGit/tree/'+pin+'/Languages\n\n'+'\n\n'.join(credits)+'\n'
    return {CREDITS:credit_text.encode(),CATALOG:catalog,MANIFEST:(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n').encode(),GENERATED:generated.encode()}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    mode=parser.add_mutually_exclusive_group()
    mode.add_argument('--write',action='store_true')
    mode.add_argument('--check',action='store_true',help='Verify generated resources (the default)')
    args=parser.parse_args()
    outputs=build()
    for path,data in outputs.items():
        if args.write:
            path.parent.mkdir(parents=True,exist_ok=True)
            if not path.exists() or path.read_bytes()!=data:path.write_bytes(data)
        elif not path.exists() or path.read_bytes()!=data:raise SystemExit('Regenerate localized labels: python3 scripts/build-localizations.py --write ('+str(path.relative_to(ROOT))+')')
    manifest=json.loads(outputs[MANIFEST]);print(json.dumps({'languages':len(manifest['languages'])+1,'keys':manifest['keys'],'mode':'write' if args.write else 'check'}))
if __name__=='__main__':main()
