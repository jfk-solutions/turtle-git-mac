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
# The original inventory remains immutable. This reviewed exception changes
# only push admission; PR checks and every inventoried native assertion remain.
DOCUMENTATION_PUSH_IGNORES = [
    'README.md', 'docs/*.md', 'docs/qa/**/*.md',
    'docs/qa/signed-consolidation-build*.json', 'docs/qa/hosted-*.json',
    'docs/site/*.html', 'docs/site/*.css', 'docs/site/manual/**',
    'docs/site/assets/mac-*.png',
]
BASELINE_HEADER = {
    'name': 'macOS',
    # Ruby's system YAML 1.1 parser represents the unquoted `on` key as true.
    'true': {'push': None, 'pull_request': None},
    'concurrency': {'group': '${{ github.workflow }}-${{ github.ref }}',
                    'cancel-in-progress': False},
}
GUARD = {'name': 'Check workflow lane contracts', 'run': 'python3 scripts/test-macos-ci-lanes.py'}
EDITOR_SETUP = {'name': 'Prepare SwiftPM editor for native and Core consumers',
                'id': 'native_ready',
                'run': 'swift build --product TurtleGitMac'}
APP_BUILD_NAME = 'Application and embedded Finder extension'
APP_BUILD_ORIGINAL_RUN = "xcodebuild -quiet -project TurtleGitMac.xcodeproj -scheme TurtleGitMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build"
APP_BUILD_RUN = ('mkdir -p build/qa\nset -o pipefail\n'
                 '{\n  xcodebuild -version\n  xcrun swift --version\n} > build/qa/app-build-toolchain.txt 2>&1\n'
                 + APP_BUILD_ORIGINAL_RUN + ' 2>&1 | tee build/qa/app-build.log\n')
APP_BUILD_EVIDENCE = {
    'name': 'Upload app-build diagnostics',
    'if': "${{ !cancelled() && steps.app_build.outcome == 'failure' }}",
    'uses': 'actions/upload-artifact@v4',
    'with': {
        'name': 'app-build-${{ matrix.lane }}-${{ github.run_id }}-${{ github.run_attempt }}',
        'path': 'build/qa/app-build.log\nbuild/qa/app-build-toolchain.txt\n',
        'if-no-files-found': 'warn',
        'retention-days': 7,
    },
}
STORE_BUILD = 'Build and audit unsigned universal App Store candidate'
REPLAY_BUILD = 'Build isolated older Git runtimes for replay tests'
STORE_AUDIT = 'Preserve unsigned distribution audit'
PANE_HEADER_CONSUMER = 'Compare and Merge pane header commands and ownership'
COLLECTION_IDS = {STORE_BUILD: 'store_ready', REPLAY_BUILD: 'replay_ready',
                  PANE_HEADER_CONSUMER: 'pane_headers'}
COLLECTION_DEPENDENCIES = {
    STORE_AUDIT: ['store_ready'],
    'Revision Graph through built Debug and Store frameworks and helpers': ['store_ready'],
    'Native packaged Git SSH client lookup without network': ['store_ready'],
    'Native AppStore bundled SSH encrypted-key loading and cleanup': ['store_ready'],
    'Native Cherry Pick and Rebase recovery across Git versions': ['store_ready', 'replay_ready'],
}

def collection_condition(name, lane):
    """Keep failures visible while collecting independent ready consumers.

    An explicit cancelled() status check overrides GitHub's implicit success()
    without starting new work after cancellation. Producers still fail closed.
    """
    terms = ['!cancelled()', "steps.native_ready.outcome == 'success'",
             "matrix.lane == '" + lane + "'"]
    terms += ["steps." + dependency + ".outcome == 'success'"
              for dependency in COLLECTION_DEPENDENCIES.get(name, [])]
    return '${{ ' + ' && '.join(terms) + ' }}'
# Explicit additions are checked in full, then removed before the
# immutable pre-split inventory comparison. It cannot excuse any producer or
# other artifact drift, nor introduce a generic class of untracked steps.
METAFILE_CONSUMER = 'WMF and EMF native comparison consumers and colors'
UTILITY_STARTUP_ANCHOR = 'First Start SSH selection and owned inspection'
UTILITY_STARTUP = {
    'name': 'Repository-independent utility and local tool startup',
    'if': collection_condition('Repository-independent utility and local tool startup', 'settings-finder'),
    'run': 'python3 scripts/test-utility-startup.py',
}
REVERT_EXACT_ANCHOR = 'Revert completed results and shared file-progress ownership'
REVERT_EXACT = {
    'name': 'Exact-name Revert clean Retry and retired result ownership',
    'if': collection_condition('Exact-name Revert clean Retry and retired result ownership', 'commit-repository'),
    'run': 'python3 scripts/test-operation-identity-family.py --only revert-exact --git /usr/bin/git --git "$PWD/build/git-runtime/Git/bin/git"',
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
STATISTICS_EXPORT_CONSUMER = 'Statistics source export filters and owned save cancellation'
STATISTICS_FAILURE_EVIDENCE = {
    'name': 'Preserve Statistics export failure evidence',
    'if': "${{ failure() && matrix.lane == 'images-documents' }}",
    'uses': 'actions/upload-artifact@v4',
    'with': {
        'name': 'statistics-export-failure-${{ github.run_id }}-${{ github.run_attempt }}',
        'path': ('build/qa/statistics-export-failed-*/**\n'
                 'build/qa/statistics-export-family-native-results.json\n'),
        'if-no-files-found': 'ignore',
        'retention-days': 7,
    },
}
ARTIFACT_NAMES = {
    'wrapped-editor-timeout-stacks': 'wrapped-editor-timeout-stacks-${{ matrix.lane }}',
    'unsigned-appstore-distribution-audit': 'unsigned-appstore-distribution-audit-${{ matrix.lane }}',
}
PANE_HEADER_FAILURE_EVIDENCE = {
    'name': 'Preserve pane header system accessibility diagnostics',
    'if': "${{ !cancelled() && steps.native_ready.outcome == 'success' && matrix.lane == 'editors' && steps.pane_headers.outcome == 'failure' }}",
    'uses': 'actions/upload-artifact@v4',
    'with': {
        'name': 'pane-header-diagnostics-${{ github.run_attempt }}',
        'path': 'build/qa/merge-pane-header-diagnostics/**',
        'if-no-files-found': 'warn',
        'retention-days': 7,
    },
}
HISTORY_CONTEXT_ANCHOR = 'Native Log selection and inspection while history streams'
HISTORY_CONTEXT = {
    'name': 'Native historical file menus and connected dialog handoffs',
    'if': collection_condition('Native historical file menus and connected dialog handoffs', 'history-references'),
    'timeout-minutes': 20,
    'run': ('mkdir -p build/qa\nset -o pipefail\n'
            'python3 scripts/test-history-file-context-family.py --keep-going --only browser-context --only blame-context --only log-context --git /usr/bin/git --git build/git-runtime/Git/bin/git --results build/qa/history-file-context-ci.json 2>&1 | tee build/qa/history-file-context-ci.log\n'),
}
HISTORY_CONTEXT_EVIDENCE = {
    'name': 'Upload historical file context diagnostics',
    'if': collection_condition('Upload historical file context diagnostics', 'history-references'),
    'uses': 'actions/upload-artifact@v4',
    'with': {
        'name': 'history-file-context-${{ github.run_id }}-${{ github.run_attempt }}',
        'path': ('build/qa/history-file-context-ci.json\n'
                 'build/qa/history-file-context-ci.log\n'
                 'build/qa/history-file-context-*-timeout.sample.txt\n'),
        'retention-days': 7,
    },
}
LOG_PRIMARY = {
    'name': 'Native mixed Log primary file activation and conflict handoffs',
    'if': collection_condition('Native mixed Log primary file activation and conflict handoffs', 'history-references'),
    'timeout-minutes': 20,
    'run': ('mkdir -p build/qa\nset -o pipefail\n'
            'python3 scripts/test-log-primary-activation-batch.py --only primary --git /usr/bin/git --git build/git-runtime/Git/bin/git --results build/qa/log-primary-activation-native-results.json 2>&1 | tee build/qa/log-primary-activation-native.log\n'),
}
LOG_PRIMARY_EVIDENCE = {
    'name': 'Upload mixed Log primary activation diagnostics',
    'if': collection_condition('Upload mixed Log primary activation diagnostics', 'history-references'),
    'uses': 'actions/upload-artifact@v4',
    'with': {
        'name': 'log-primary-activation-${{ github.run_id }}-${{ github.run_attempt }}',
        'path': ('build/qa/log-primary-activation-native-results.json\n'
                 'build/qa/log-primary-activation-native.log\n'
                 'build/qa/log-primary-activation-primary-*-timeout.sample.txt\n'),
        'if-no-files-found': 'warn',
        'retention-days': 7,
    },
}

# Reviewed connected status-list consumers. Exact commands, guards and local
# neighbors are required before removing these from the immutable baseline walk.
SYNC_REPLAY_SELECTED = {
    'name': 'Native Sync and replay selected file activation',
    'if': collection_condition('Native Sync and replay selected file activation', 'replay-transport'),
    'run': 'python3 scripts/test-status-primary-activation.py --only sync --only replay --git /usr/bin/git --git "$PWD/build/git-runtime/Git/bin/git"',
}
RESOLVE_OPERANDS = {
    'name': 'Native Resolve HEAD and unified comparison operands',
    'if': collection_condition('Native Resolve HEAD and unified comparison operands', 'replay-transport'),
    'run': 'python3 scripts/test-conflict-comparison-operands.py --git /usr/bin/git --git "$PWD/build/git-runtime/Git/bin/git"',
}
LOG_SELECTED = {
    'name': 'Native Log selected file activation',
    'if': collection_condition('Native Log selected file activation', 'history-references'),
    'run': 'python3 scripts/test-status-primary-activation.py --only log --git /usr/bin/git --git "$PWD/build/git-runtime/Git/bin/git"',
}
LOG_OPERANDS = {
    'name': 'Native Log working-list comparison operands',
    'if': collection_condition('Native Log working-list comparison operands', 'history-references'),
    'run': 'python3 scripts/test-log-working-comparison-operands.py --git /usr/bin/git --git "$PWD/build/git-runtime/Git/bin/git"',
}
ADD_OPERANDS = {
    'name': 'Native Add accepted comparison operands',
    'if': collection_condition('Native Add accepted comparison operands', 'commit-repository'),
    'run': 'python3 scripts/test-add-comparison-operands.py --git /usr/bin/git --git "$PWD/build/git-runtime/Git/bin/git"',
}
COMMIT_WORKING_SELECTED = {
    'name': 'Native Commit Working Tree and Resolve selected file activation',
    'if': collection_condition('Native Commit Working Tree and Resolve selected file activation', 'commit-repository'),
    'run': 'python3 scripts/test-status-primary-activation.py --only legacy --only status --only add-resolve --git /usr/bin/git --git "$PWD/build/git-runtime/Git/bin/git"',
}
STATUS_OPERANDS = {
    'name': 'Native accepted status comparison operands',
    'if': collection_condition('Native accepted status comparison operands', 'commit-repository'),
    'run': 'python3 scripts/test-status-comparison-operands.py --git /usr/bin/git --git "$PWD/build/git-runtime/Git/bin/git"',
}
WORKING_STATUS_PROJECTION = {
    'name': 'Native natural Copy and Rename working status projection',
    'if': collection_condition('Native natural Copy and Rename working status projection', 'commit-repository'),
    'run': 'python3 scripts/test-working-status-projection.py --only commit --only status --only add --only log --only revert --git /usr/bin/git --git "$PWD/build/git-runtime/Git/bin/git"',
}
SCOPED_WORKING_READS = {
    'name': 'Native scoped working reads and immutable retry',
    'if': collection_condition('Native scoped working reads and immutable retry', 'commit-repository'),
    'run': 'python3 scripts/test-scoped-working-reads.py --only add --only revert --only rescope-cancel --only commit --git /usr/bin/git --git "$PWD/build/git-runtime/Git/bin/git"',
}
BLAME_SOURCE_NAME = 'Native Blame captured source menus'
BLAME_SOURCE_ORIGINAL_RUN = 'python3 scripts/test-blame-source-menu.py --only commands --only source-menu --git /usr/bin/git --git build/Build/Products/Debug/TurtleGitMac.app/Contents/Resources/TurtleGitRuntimes/Git/bin/git'
BLAME_SOURCE_FOCUS_RUN = 'python3 scripts/test-blame-source-menu.py --only commands --only source-menu --only focus --git /usr/bin/git --git build/Build/Products/Debug/TurtleGitMac.app/Contents/Resources/TurtleGitRuntimes/Git/bin/git'
STATUS_CONSUMER_ADDITIONS = (
    ('Native primary command launch family', (SYNC_REPLAY_SELECTED, RESOLVE_OPERANDS),
     'Native invocation-owned progress completion and deferred handoffs'),
    (BLAME_SOURCE_NAME, (LOG_SELECTED, LOG_OPERANDS),
     'Native Blame retained-byte encoding recovery and cancellation'),
    ('Native Commit staging activation and preference lifetime', (ADD_OPERANDS,),
     'Native Commit source category checking'),
    ('Native Commit source category checking', (COMMIT_WORKING_SELECTED, STATUS_OPERANDS, WORKING_STATUS_PROJECTION, SCOPED_WORKING_READS),
     'Native Commit report rows, fonts and geometry ownership'),
)

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
    require(inventory['workflowHeader'] == BASELINE_HEADER, 'Original workflow header inventory changed')
    expected_header = copy.deepcopy(BASELINE_HEADER)
    expected_header['true']['push'] = {'paths-ignore': DOCUMENTATION_PUSH_IGNORES}
    require({key: value for key, value in workflow.items() if key != 'jobs'} == expected_header,
            'Workflow trigger or inherited configuration changed beyond documentation-only push admission')
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
    revert_exact = [i for i, step in enumerate(actual) if step.get('name') == REVERT_EXACT['name']]
    revert_anchors = [i for i, step in enumerate(actual) if step.get('name') == REVERT_EXACT_ANCHOR]
    require(len(revert_exact) == 1 and len(revert_anchors) == 1,
            'Missing or duplicate exact-name Revert consumer/anchor')
    require(revert_exact[0] == revert_anchors[0] + 1 and actual[revert_exact[0]] == REVERT_EXACT,
            'Exact-name Revert command, owner, readiness/cancellation condition or placement changed')
    # Remove only this fully verified addition. The original Revert producer and
    # every neighboring step still pass the immutable baseline comparison below.
    actual.pop(revert_exact[0])
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
    statistics_evidence = [i for i, step in enumerate(actual)
                           if step.get('name') == STATISTICS_FAILURE_EVIDENCE['name']]
    statistics_consumers = [i for i, step in enumerate(actual)
                            if step.get('name') == STATISTICS_EXPORT_CONSUMER]
    require(len(statistics_evidence) == 1, 'Missing or duplicate exact Statistics failure-evidence step')
    require(len(statistics_consumers) == 1, 'Missing or duplicate inventoried Statistics export consumer')
    require(statistics_evidence[0] == statistics_consumers[0] + 1,
            'Statistics failure evidence must immediately follow its export producer')
    require(actual[statistics_evidence[0]] == STATISTICS_FAILURE_EVIDENCE,
            'Changed Statistics failure artifact action, owner/condition, name, paths, retention or missing-file policy')
    actual.pop(statistics_evidence[0])
    header_evidence = [i for i, step in enumerate(actual)
                       if step.get('name') == PANE_HEADER_FAILURE_EVIDENCE['name']]
    header_consumers = [i for i, step in enumerate(actual)
                        if step.get('name') == PANE_HEADER_CONSUMER]
    require(len(header_evidence) == 1 and len(header_consumers) == 1,
            'Missing or duplicate pane-header consumer/evidence step')
    require(header_evidence[0] == header_consumers[0] + 1,
            'Pane-header evidence must immediately follow its owned consumer')
    require(actual[header_evidence[0]] == PANE_HEADER_FAILURE_EVIDENCE,
            'Changed pane-header diagnostic owner/guards/action/paths/retention')
    actual.pop(header_evidence[0])
    # This exact connected history family is reviewed independently of the
    # immutable baseline. No other new step or original neighbor is exempted.
    history_additions = [HISTORY_CONTEXT, HISTORY_CONTEXT_EVIDENCE,
                         LOG_PRIMARY, LOG_PRIMARY_EVIDENCE]
    history_anchors = [i for i, step in enumerate(actual)
                       if step.get('name') == HISTORY_CONTEXT_ANCHOR]
    require(len(history_anchors) == 1, 'Missing or duplicate history-context anchor')
    history_start = history_anchors[0] + 1
    for offset, expected in enumerate(history_additions):
        require(sum(step.get('name') == expected['name'] for step in actual) == 1,
                'Missing or duplicate reviewed history addition: ' + expected['name'])
        require(actual[history_start + offset] == expected,
                'Changed history command, lane/readiness/cancellation, placement or diagnostic contract: ' + expected['name'])
    del actual[history_start:history_start + len(history_additions)]
    for anchor, additions, following in STATUS_CONSUMER_ADDITIONS:
        anchors = [i for i, step in enumerate(actual) if step.get('name') == anchor]
        require(len(anchors) == 1, 'Missing or duplicate status-family anchor: ' + anchor)
        start = anchors[0] + 1
        for offset, expected in enumerate(additions):
            require(sum(step.get('name') == expected['name'] for step in actual) == 1,
                    'Missing or duplicate reviewed status consumer: ' + expected['name'])
            require(start + offset < len(actual) and actual[start + offset] == expected,
                    'Changed status command, lane/readiness/cancellation or placement: ' + expected['name'])
        require(start + len(additions) < len(actual) and actual[start + len(additions)].get('name') == following,
                'Changed status-family following neighbor: ' + following)
        del actual[start:start + len(additions)]
    app_index = next(i for i, step in enumerate(originals) if step.get('name') == 'Application and embedded Finder extension')
    evidence = [i for i, step in enumerate(actual) if step.get('name') == APP_BUILD_EVIDENCE['name']]
    require(len(evidence) == 1 and evidence[0] == app_index + 1,
            'Missing, duplicate or detached app-build evidence')
    require(actual[evidence[0]] == APP_BUILD_EVIDENCE,
            'Changed app-build artifact failure/cancellation guard, action, paths, name or retention')
    actual.pop(evidence[0])
    require(actual[app_index + 1] == EDITOR_SETUP,
            'Every lane needs the unconditional SwiftPM executable before native/Core consumers')
    actual.pop(app_index + 1)
    require(len(actual) == len(originals), 'New/unmapped, removed or duplicate workflow step')
    assignments = {}
    for position, (record, before, after) in enumerate(zip(records, originals, actual)):
        expected = copy.deepcopy(before)
        name = expected.get('name', expected.get('uses'))
        require(record['name'] == name, 'Inventory identity mismatch: ' + record['id'])
        lane = record['lane']
        if lane != 'bootstrap':
            condition = "matrix.lane == '" + lane + "'"
            if 'if' in expected:
                condition += ' && (' + str(expected['if']) + ')'
            expected['if'] = condition
            if position > app_index and lane != 'core' and ('run' in before or name == STORE_AUDIT):
                require('if' not in before, 'Unreviewed conditional consumer: ' + name)
                expected['if'] = collection_condition(name, lane)
        if name in COLLECTION_IDS:
            expected['id'] = COLLECTION_IDS[name]
        if name == APP_BUILD_NAME:
            require(before.get('run') == APP_BUILD_ORIGINAL_RUN,
                    'Reviewed app-build baseline command changed')
            expected['id'] = 'app_build'
            expected['run'] = APP_BUILD_RUN
        if name == APP_BUILD_NAME:
            require(before.get('run') == APP_BUILD_ORIGINAL_RUN,
                    'Reviewed app-build baseline command changed')
            expected['id'] = 'app_build'
            expected['run'] = APP_BUILD_RUN
        if name == BLAME_SOURCE_NAME:
            require(before.get('run') == BLAME_SOURCE_ORIGINAL_RUN,
                    'Reviewed Blame source-menu baseline command changed')
            expected['run'] = BLAME_SOURCE_FOCUS_RUN
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
    require({key: value for key, value in yaml_document(original).items() if key != 'jobs'} == inventory['workflowHeader'],
            'Inventory differs from committed pre-split workflow header')
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
