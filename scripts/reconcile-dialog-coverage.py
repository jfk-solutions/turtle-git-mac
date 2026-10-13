#!/usr/bin/env python3
"""Reconcile explicit partial family audits; never infer complete dialog parity."""
import argparse
import collections
import csv
import io
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent

def read_csv(path):
    with path.open(newline='') as stream: return list(csv.DictReader(stream))

def csv_text(rows):
    stream = io.StringIO(newline=''); writer = csv.DictWriter(stream, fieldnames=list(rows[0]), lineterminator='\n')
    writer.writeheader(); writer.writerows(rows); return stream.getvalue()

def reconcile(root):
    pin = json.loads((root/'docs/upstream.json').read_text())
    reviews = json.loads((root/'docs/dialog-coverage-reviews.json').read_text())
    if reviews['upstream_commit'] != pin['commit']: raise ValueError('Dialog review catalogue must be re-audited after an upstream repin.')
    dialogs = read_csv(root/'docs/upstream-dialogs.csv'); controls = read_csv(root/'docs/upstream-controls.csv')
    keys = {(r['resource'],r['id']) for r in dialogs}
    if len(keys) != len(dialogs): raise ValueError('Duplicate dialog resource identity')
    overrides = {}
    for review in reviews['reviews']:
        key = (review['resource'],review['id'])
        if key not in keys or key in overrides: raise ValueError('Unknown/duplicate review: ' + str(key))
        if review['status'] not in {'partial','partial-native','partial-native-replacement','native-partial','partial-workflow-replacement'}: raise ValueError('Family reviews cannot certify complete parity')
        document = root/review['parity_document']
        if not document.is_file(): raise ValueError('Missing parity document: ' + str(document))
        for native in review['native_sources']:
            path = root/native['path']
            if not path.is_file() or native['anchor'] not in path.read_text(): raise ValueError('Missing native reference: ' + str(native))
        overrides[key] = review
    grouped = collections.defaultdict(list)
    for control in controls:
        key = (control['resource'],control['dialog'])
        if key not in keys: raise ValueError('Control references an unknown dialog: ' + str(key))
        grouped[key].append(control)
    for dialog in dialogs:
        key = (dialog['resource'],dialog['id'])
        if key in overrides:
            if dialog['status'] == 'upstream-changed-needs-review': raise ValueError('Review changed source before reconciliation: ' + str(key))
            dialog['status'] = overrides[key]['status']
    id_counts = collections.Counter(r['id'] for r in dialogs)
    files = {r['path']:r for r in read_csv(root/'docs/upstream-files.csv')}
    document_ids = collections.defaultdict(set); document_evidence = {}
    for path in sorted((root/'docs').glob('*.md')):
        if path.name == 'DIALOG-COVERAGE.md': continue
        text = path.read_text(); name = 'docs/' + path.name
        for identifier in set(re.findall(r'\bIDD_[A-Z0-9_]+\b', text)): document_ids[identifier].add(name)
        document_evidence[name] = {'docs/' + match for match in re.findall(r'qa/[A-Za-z0-9_.-]+[.]json', text) if (root/'docs'/match).is_file()}
    entries = []
    for dialog in dialogs:
        key = (dialog['resource'],dialog['id']); review = overrides.get(key)
        docs = set([review['parity_document']]) if review else set()
        if id_counts[dialog['id']] == 1: docs.update(document_ids[dialog['id']])
        evidence = set()
        for document in docs: evidence.update(document_evidence.get(document, set()))
        items = grouped[key]; mapped = sum(bool(r['native_mapping']) for r in items)
        pending = sum(r['status'] in {'pending-review', 'upstream-changed-needs-review'} for r in items)
        native_sources = list(review['native_sources']) if review else []
        known = {r['path'] for r in native_sources}; missing = set()
        for item in items:
            for path in re.findall(r'Sources/[A-Za-z0-9_./-]+[.](?:swift|cpp|h|m)', item['native_mapping']):
                if not (root/path).is_file(): missing.add(path)
                elif path not in known:
                    native_sources.append({'path':path,'origin':'recorded-control-mapping'}); known.add(path)
        entries.append(dict(dialog, source_blob=files[dialog['resource']]['blob'], static_controls=len(items), mapped_controls=mapped,
                            pending_control_reviews=pending, certified_complete=False,
                            native_sources=native_sources, missing_native_references=sorted(missing),
                            parity_documents=sorted(docs), qa_records=sorted(evidence)))
    statuses = collections.Counter(r['status'] for r in entries)
    summary = {'dialogs':len(entries), 'partial_family_audits':sum('partial' in r['status'] for r in entries),
               'pending_family_reviews':sum(r['status']=='pending-review' for r in entries),
               'certified_complete':0,'static_controls':len(controls),
               'pending_control_reviews':sum(r['status'] in {'pending-review', 'upstream-changed-needs-review'} for r in controls),
               'mapped_controls':sum(bool(r['native_mapping']) for r in controls), 'statuses':dict(statuses)}
    ledger = {'upstream_commit':pin['commit'], 'scope':'Family/control audit coverage; not a feature-completion percentage or signed acceptance.', 'summary':summary, 'dialogs':entries}
    text = '# Dialog coverage and remaining review\n\n'
    text += f"The pinned inventory contains **{summary['dialogs']} dialogs**: **{summary['partial_family_audits']} have partial family audits**, **{summary['pending_family_reviews']} await a family review**, and **none are certified complete**.\n\n"
    text += f"There are {summary['static_controls']} inventoried static controls. {summary['mapped_controls']} have recorded native mappings; {summary['pending_control_reviews']} still have pending control reviews. Dynamic menus, runtime-created controls, full layout and signed acceptance require separate evidence. A partial family audit never clears its unmapped controls. Recorded control mappings also remain partial; they do not prove all associated behavior.\n\n"
    text += 'This generated table links explicit implementation/parity reviews and existing QA. Missing links indicate missing recorded evidence, rather than proof that a feature is absent. The full machine-readable ledger is [dialog coverage](dialog-coverage.json). Review decisions live in `dialog-coverage-reviews.json`; regeneration is pinned to the source commit.\n\n'
    text += '| Source dialog | Family audit | Static control mappings | Recorded parity/evidence |\n| --- | --- | --- | --- |\n'
    for row in entries:
        links = ', '.join(f'[{Path(p).stem}]({Path(p).name})' for p in row['parity_documents']) or 'No recorded family document'
        text += f"| `{row['resource']}` / `{row['id']}` | {row['status']} | {row['mapped_controls']}/{row['static_controls']} mapped; {row['pending_control_reviews']} pending | {links}; {len(row['qa_records'])} QA records |\n"
    return dialogs, ledger, text

def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--check', action='store_true'); args=parser.parse_args()
    dialogs, ledger, text = reconcile(ROOT)
    outputs = {ROOT/'docs/upstream-dialogs.csv':csv_text(dialogs), ROOT/'docs/dialog-coverage.json':json.dumps(ledger,indent=2)+'\n', ROOT/'docs/DIALOG-COVERAGE.md':text}
    for path, content in outputs.items():
        if args.check:
            if not path.is_file() or path.read_text() != content: raise SystemExit('Regenerate dialog coverage: ' + str(path))
        else: path.write_text(content)
    print(json.dumps(ledger['summary']))

if __name__ == '__main__': main()
