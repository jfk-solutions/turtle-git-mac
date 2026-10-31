#!/usr/bin/env python3
"""Fail closed if the macOS split drops, duplicates or changes an inventoried step.

The inventory records the pre-split committed workflow, including command, env,
uses/with and original conditions. Ruby's macOS system YAML parser avoids adding
an external Python package to the CI bootstrap.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
INVENTORY = ROOT / 'Configuration/CI/MacOSValidationInventory.json'
WORKFLOW = ROOT / '.github/workflows/macos.yml'
LANES = ['core', 'commit-repository', 'history-references', 'replay-transport',
         'editors', 'settings-finder', 'images-documents', 'distribution']
GUARD = {'name': 'Check workflow lane contracts', 'run': 'python3 scripts/test-macos-ci-lanes.py'}
EDITOR_SETUP = {'name': 'Prepare SwiftPM editor for native and Core consumers',
                'run': 'swift build --product TurtleGitMac'}
# Explicit additions are checked in full, then removed before the
# immutable pre-split inventory comparison. It cannot excuse any producer or
# other artifact drift, nor introduce a generic class of untracked steps.
METAFILE_CONSUMER = 'WMF and EMF native comparison consumers and colors'
UTILITY_STARTUP_ANCHOR = 'First Start SSH selection and owned inspection'
UTILITY_STARTUP = {
    'name': 'Repository-independent utility and local tool startup',
    'if': "matrix.lane == 'settings-finder'",
    'run': 'python3 scripts/test-utility-startup.py',
}
METAFILE_FAILURE_EVIDENCE = {
    'name': 'Retain failed metafile source and pixel evidence',
    'if': "matrix.lane == 'commit-repository' && failure()",
    'uses': 'actions/upload-artifact@v4',
    'with': {
        'name': 'metafile-pixel-evidence-${{ matrix.lane }}',
        'path': ('build/qa/metafile-workflow-failures/**\n'
                 'build/qa/metafile-wmf-text-native-results.json\n'
                 'build/qa/metafile-wmf-text-runtime-*.json\n'),
        'if-no-files-found': 'ignore',
    },
}
ARTIFACT_NAMES = {
    'wrapped-editor-timeout-stacks': 'wrapped-editor-timeout-stacks-${{ matrix.lane }}',
    'unsigned-appstore-distribution-audit': 'unsigned-appstore-distribution-audit-${{ matrix.lane }}',
}

def yaml_document(text):
    result = subprocess.run(['ruby', '-rjson', '-ryaml', '-e',
        'print JSON.generate(YAML.load(STDIN.read))'], input=text, text=True,
        capture_output=True, check=True)
    return json.loads(result.stdout)

def original_steps(inventory):
    return yaml_document('steps:\n' + ''.join(item['step'] for item in inventory['steps']))['steps']

def require(value, message):
    if not value:
        raise AssertionError(message)

def verify(workflow, inventory, originals):
    require(inventory['schema'] == 1 and inventory['lanes'] == LANES, 'Unknown inventory schema/lanes')
    records = inventory['steps']
    require(len(records) == len(originals), 'Inventory parse lost a step')
    require(len({record['id'] for record in records}) == len(records), 'Duplicate inventory ID')
    require(all(record['lane'] in LANES + ['bootstrap'] for record in records), 'Unmapped inventory lane')
    require({key: value for key, value in workflow.items() if key != 'jobs'} == inventory['workflowHeader'], 'Workflow trigger or inherited configuration changed')
    require(workflow['concurrency'] == {'group': '${{ github.workflow }}-${{ github.ref }}',
                                       'cancel-in-progress': False}, 'Concurrency policy changed')
    jobs = workflow['jobs']
    require(set(jobs) == {'svn-runtime', 'validation', 'build-and-test'}, 'Unknown/missing jobs')
    expected_svn = copy.deepcopy(inventory['svnProducer'])
    expected_svn['timeout-minutes'] = 300
    require(jobs['svn-runtime'] == expected_svn, 'Original SVN producer command/env/action changed')
    worker = jobs['validation']
    require(set(worker) == {'name', 'needs', 'runs-on', 'timeout-minutes', 'strategy', 'steps'}, 'Unknown worker configuration/inherited env')
    require(worker['name'] == 'validation (${{ matrix.lane }})', 'Worker status label changed')
    require(worker['needs'] == 'svn-runtime' and worker['runs-on'] == 'macos-15-intel', 'Worker dependency/host changed')
    require(worker['strategy'] == {'fail-fast': False, 'max-parallel': 4, 'matrix': {'lane': LANES}}, 'Matrix coverage/failure policy changed')
    require(worker.get('timeout-minutes') == 300 and jobs['svn-runtime'].get('timeout-minutes') == 300, 'Unbounded/changed macOS timeout')
    actual = list(worker['steps'])
    require(actual[1] == GUARD, 'Missing initial fail-closed coverage check')
    actual.pop(1)
    utility = [i for i, step in enumerate(actual) if step.get('name') == UTILITY_STARTUP['name']]
    anchors = [i for i, step in enumerate(actual) if step.get('name') == UTILITY_STARTUP_ANCHOR]
    require(len(utility) == 1 and len(anchors) == 1, 'Missing or duplicate utility startup check/anchor')
    require(utility[0] == anchors[0] + 1 and actual[utility[0]] == UTILITY_STARTUP,
            'Utility startup command, owner, condition or placement changed')
    actual.pop(utility[0])
    evidence = [i for i, step in enumerate(actual)
                if step.get('name') == METAFILE_FAILURE_EVIDENCE['name']]
    consumers = [i for i, step in enumerate(actual)
                 if step.get('name') == METAFILE_CONSUMER]
    require(len(evidence) == 1, 'Missing or duplicate exact metafile failure-evidence step')
    require(len(consumers) == 1, 'Missing or duplicate inventoried metafile consumer')
    require(evidence[0] == consumers[0] + 1,
            'Metafile failure evidence must immediately follow its source/pixel producer')
    require(actual[evidence[0]] == METAFILE_FAILURE_EVIDENCE,
            'Changed metafile failure artifact action, owner/condition, name, paths or missing-file policy')
    actual.pop(evidence[0])
    app_index = next(i for i, step in enumerate(originals) if step.get('name') == 'Application and embedded Finder extension')
    require(actual[app_index + 1] == EDITOR_SETUP,
            'Every lane needs the unconditional SwiftPM executable before native/Core consumers')
    actual.pop(app_index + 1)
    require(len(actual) == len(originals), 'New/unmapped, removed or duplicate workflow step')
    assignments = {}
    for record, before, after in zip(records, originals, actual):
        expected = copy.deepcopy(before)
        name = expected.get('name', expected.get('uses'))
        require(record['name'] == name, 'Inventory identity mismatch: ' + record['id'])
        lane = record['lane']
        if lane != 'bootstrap':
            condition = "matrix.lane == '" + lane + "'"
            if 'if' in expected:
                condition += ' && (' + str(expected['if']) + ')'
            expected['if'] = condition
        if expected.get('uses') == 'actions/upload-artifact@v4':
            prior = expected['with']['name']
            require(prior in ARTIFACT_NAMES, 'Unmapped artifact ownership')
            expected['with']['name'] = ARTIFACT_NAMES[prior]
        require(after == expected, 'Changed command/env/action/condition or reordered step: ' + record['id'] + ' ' + name)
        assignments[name] = lane
    # These consumers rely on same-job output, not just source checkout.
    for name in ['Git integration tests', 'Working copy revision utility and upstream templates',
                 'SVN command compatibility with pinned Git', 'Synchronization comparisons and transport with bundled Git',
                 'Patch mail preparation with packaged Git', 'Revision Graph data and geometry with bundled Git']:
        require(assignments[name] == 'core', 'SwiftPM producer/consumer split: ' + name)
    distribution = ['Build and audit unsigned universal App Store candidate',
                    'Revision Graph through built Debug and Store frameworks and helpers',
                    'Native AppStore bundled SSH encrypted-key loading and cleanup',
                    'Build isolated older Git runtimes for replay tests',
                    'Native Cherry Pick and Rebase recovery across Git versions']
    for name in distribution:
        require(assignments[name] == 'distribution', 'Store/replay producer/consumer split: ' + name)
    require(assignments['Application and embedded Finder extension'] == 'bootstrap', 'Every lane needs its native framework/modules')
    require(assignments['Retain failed wrapped editor stack samples'] == assignments['Moved blocks and wrapped editor navigation family'] == 'editors', 'Failure artifact detached from producer')
    aggregate = jobs['build-and-test']
    require(aggregate['name'] == 'build-and-test' and aggregate['if'] == 'always()', 'Required status identity/always policy changed')
    require(aggregate['needs'] == ['svn-runtime', 'validation'] and aggregate['timeout-minutes'] == 5, 'Aggregate does not wait for all producers/lanes')
    require(len(aggregate['steps']) == 1, 'Unexpected aggregate side effects')
    step = aggregate['steps'][0]
    require(step['env'] == {'NEEDS_JSON': '${{ toJSON(needs) }}'}, 'Aggregate result capture changed')
    # Exercise the actual aggregate Python with successful and failed/skipped jobs in tests.
    require(step['run'].startswith("python3 - <<'PY'\n") and step['run'].endswith('\nPY\n'), 'Unknown aggregate script')
    return assignments

def verify_baseline(inventory):
    original = subprocess.check_output(['git', 'show', inventory['baselineCommit'] + ':.github/workflows/macos.yml'], cwd=ROOT, text=True)
    require(hashlib.sha256(original.encode()).hexdigest() == inventory['baselineWorkflowSHA256'], 'Committed baseline hash mismatch')
    # Compare semantic steps to the original committed source, not counts alone.
    committed = yaml_document(original)['jobs']['build-and-test']['steps']
    require(committed == original_steps(inventory), 'Inventory differs from committed pre-split commands/env/actions')
    require(yaml_document(original)['jobs']['svn-runtime'] == inventory['svnProducer'], 'Inventory differs from committed SVN producer')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify-baseline', action='store_true', help='also require the recorded pre-split Git object (local full checkout)')
    args = parser.parse_args()
    inventory = json.loads(INVENTORY.read_text())
    if args.verify_baseline:
        verify_baseline(inventory)
    assignments = verify(yaml_document(WORKFLOW.read_text()), inventory, original_steps(inventory))
    print('macOS workflow coverage: every inventoried step preserved; eight bounded lanes, dependency and required-status contracts checked.')
