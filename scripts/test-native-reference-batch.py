#!/usr/bin/env python3
"""Link reference-family QA once against the built app; run owned bounded receivers."""
import argparse
import ast
from contextlib import ExitStack
import hashlib
import os
from pathlib import Path
import platform
import signal
import subprocess
import tempfile
import time

CASES = {
    'settings-family': 'SettingsFamilyVerification',
    'ssh-coordinator': 'SSHCoordinatorReceiver',
    'reset-progress': 'ResetProgressVerification',
    'switch-progress': 'SwitchProgressVerification',
    'stash-save-progress': 'StashSaveProgressVerification',
    'progress-auto-close': 'ProgressAutoCloseVerification',
    'local-command-progress': 'LocalCommandProgressVerification',
    'rebase-references': 'RebaseReferencesVerification',
    'rebase-row-drag': 'RebaseRowDragVerification',
    'rebase-conditional': 'RebaseConditionalVerification',
    'rebase-columns': 'RebaseColumnsVerification',
    'commit-preferences': 'CommitPreferencesVerification',
    'log-reference-navigation': 'LogReferenceNavigationVerification',
    'log-progressive-rows': 'LogProgressiveRowsVerification',
    'log-history-stream': 'LogHistoryStreamVerification',
    'log-metadata': 'LogMetadataVerification',
    'log-column-layout': 'LogColumnLayoutVerification',
    'reflog-reference-deletion': 'RefLogReferenceDeletionVerification',
    'reflog-advanced': 'RefLogAdvancedVerification',
    'reflog-notes-patch': 'RefLogNotesPatchVerification',
    'reflog-operations': 'RefLogOperationVerification',
    'reflog-table': 'RefLogTableVerification',
    'merge-clipboard': 'MergeClipboardVerification',
    'merge-source': 'ThreePaneEndingsVerification',
    'ignore-workflow': 'IgnoreWorkflowVerification',
    'version-combo': 'VersionComboVerification',
    'switch-pickers': 'SwitchPickerVerification',
    'creation-pickers': 'CreationPickerVerification',
    'add-dialog': 'AddDialogVerification',
    'add-drop': 'AddDropVerification',
    'commit-drop': 'CommitDropVerification',
    'commit-file-workflows': 'CommitFileWorkflowsVerification',
    'input-hosts': 'InputHostsVerification',
    'input-dialogs': 'InputDialogsVerification',
    'description': 'ReferenceDescriptionVerification',
    'fetch-history': 'FetchHistoryVerification',
    'remote-dialogs': 'RemoteDialogsVerification',
    'file-patches': 'FilePatchesVerification',
    'bisect-lifecycle': 'BisectLifecycleVerification',
    'bisect-progress': 'BisectProgressVerification',
    'history-workflows': 'HistoryWorkflowsVerification',
    'log-changed-files': 'LogChangedFilesVerification',
    'rebase-session-refresh': 'RebaseSessionRefreshVerification',
    'removal-progress': 'RemovalProgressVerification',
    'merge-result-colors': 'MergeResultColorsVerification',
    'rebase-replay-progress': 'RebaseReplayProgressVerification',
    'finder-transfer': 'FinderTransferVerification',
    'file-transfer': 'FileTransferVerification',
    'file-move': 'FileMoveVerification',
    'conflict-editor-routing': 'ConflictEditorRoutingVerification',
    'rebase-conflict-menus': 'RebaseConflictMenusVerification',
    'conflict-review': 'ConflictReviewVerification',
    'resolve-progress': 'ResolveProgressVerification',
    'primary-dialog-captures': 'PrimaryDialogCapture',
    'message-spelling': 'MessageSpellingVerification',
    'git-askpass': 'GitAskpassVerification',
    'patch-review-lifecycle': 'PatchReviewLifecycleVerification',
    'ssh-authentication': 'SSHAuthenticationVerification',
    'git-properties': 'GitPropertiesVerification',
    'partial-patch': 'PartialPatchVerification',
    'finder-service-grants': 'FinderServiceGrantVerification',
    'finder-service-grant-worker': 'FinderServiceGrantWorker',
    'finder-watches': 'FinderWatchVerification',
    'finder-watches-captures': 'FinderWatchCapture',
    'finder-publication': 'FinderPublicationVerification',
    'finder-publication-worker': 'FinderPublicationWorker',
    'finder-events': 'FinderEventVerification',
    'repository-browser-table-captures': 'RepositoryBrowserTableCapture',
    'ssh-key-import': 'SSHKeyImportVerification',
    'worktree-family': 'WorktreeDialogVerification',
    'worktree-progress': 'WorktreeProgressVerification',
    'revision-graph': 'RevisionGraphVerification',
    'repository-browser-table': 'RepositoryBrowserTableVerification',
    'repository-browser': 'RepositoryBrowserLifecycleVerification',
    'folders': 'ReferenceFolderVerification',
    'comparison': 'ReferenceComparisonVerification',
    'batch-delete': 'BatchReferenceDeleteVerification',
    'delete': 'ReferenceDeleteVerification',
    'switch': 'ReferenceSwitchVerification',
    'fetch': 'ReferenceFetchVerification',
    'create-branch': 'ReferenceCreateBranchVerification',
    'merge': 'ReferenceMergeVerification',
    'merge-pickers': 'MergePickerVerification',
    'network-settings': 'NetworkSettingsVerification',
    'credential-settings': 'CredentialSettingsVerification',
    'tool-settings': 'ToolSettingsVerification',
    'external-merge-lifecycle': 'ExternalMergeLifecycleVerification',
    'overlay-settings': 'OverlaySettingsVerification',
    'email-settings': 'EmailSettingsVerification',
    'commit-progress': 'CommitProgressVerification',
    'svn-workflow': 'SVNWorkflowVerification',
    'working-tree-lfs': 'WorkingTreeLFSVerification',
    'submodule-handoffs': 'SubmoduleHandoffsVerification',
    'advanced-list-consumers': 'AdvancedListConsumersVerification',
    'comparison-launch': 'ComparisonLaunchVerification',
    'file-list-layout': 'FileListLayoutVerification',
    'working-tree-groups': 'WorkingTreeGroupsVerification',
    'working-tree-file-menu': 'WorkingTreeFileMenuVerification',
    'working-tree-scope': 'WorkingTreeScopeVerification',
    'working-tree-lifecycle': 'WorkingTreeLifecycleVerification',
    'sync-hooks': 'SyncHooksVerification',
    'stash-restore': 'StashRestoreVerification',
    'blame-menus': 'BlameMenuVerification',
    'blame-file-open': 'BlameFileOpenVerification',
    'blame-find': 'BlameFindVerification',
    'blame-source': 'BlameSourceEditorVerification',
    'blame-lexilla': 'BlameLexillaVerification',
    'blame-wrap': 'BlameWrapVerification',
    'blame-wrap-captures': 'BlameWrapCapture',
    'blame-captures': 'BlameSourceCapture',
    'client-hooks': 'ClientHooksVerification',
    'autotext-tester': 'AutotextTesterVerification',
    'issue-regex-tester': 'IssueRegexTesterVerification',
    'issue-tracker-settings': 'IssueTrackerSettingsVerification',
    'utility-captures': 'UtilityDialogCapture',
    'issue-captures': 'IssueTrackerCapture',
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--git', type=Path, action='append')
parser.add_argument('--only', choices=CASES, action='append')
args = parser.parse_args()
compiled_cases = dict(CASES) if not args.only else {case: CASES[case] for case in CASES if case in args.only}
for parent, worker in [('finder-service-grants', 'finder-service-grant-worker'), ('finder-publication', 'finder-publication-worker')]:
    if parent in compiled_cases: compiled_cases[worker] = CASES[worker]
root = Path(__file__).resolve().parent.parent
products = root / 'build/Build/Products/Debug'
objects = sorted((root / 'build/Build/Intermediates.noindex/TurtleGitMac.build/Debug/TurtleGitMac.build/Objects-normal' / platform.machine()).glob('*.o'))
if not objects or not (products / 'TurtleGitMac.swiftmodule').exists():
    raise SystemExit('Build TurtleGitMac Debug before running reference QA.')
driver = ast.parse((root / 'scripts/test-synchronization-dialog.py').read_text())
helper = next(n for n in driver.body if isinstance(n, ast.FunctionDef) and n.name == 'close_receiver')
cleanup = {'os': os, 'signal': signal, 'time': time, 'subprocess': subprocess}
exec(compile(ast.Module(body=[helper], type_ignores=[]), '<owned reference receiver cleanup>', 'exec'), cleanup)
with ExitStack() as fixture_lifetimes, tempfile.TemporaryDirectory(prefix='TurtleGitReferenceNativeBatch-') as temporary:
    directory = Path(temporary)
    sources = []
    for case in compiled_cases:
        source = directory / (case + '.swift')
        fixture = root / ('docs/qa/removal-progress-native-2026-10-14.swift' if case == 'removal-progress' else 'docs/qa/merge-result-colors-native-2026-10-14.swift' if case == 'merge-result-colors' else 'docs/qa/rebase-replay-progress-native-2026-10-14.swift' if case == 'rebase-replay-progress' else 'docs/qa/finder-transfer-native-2026-10-14.swift' if case == 'finder-transfer' else 'docs/qa/file-transfer-native-2026-10-14.swift' if case == 'file-transfer' else 'docs/qa/file-move-native-2026-10-14.swift' if case == 'file-move' else 'docs/qa/conflict-editor-routing-native-2026-10-14.swift' if case == 'conflict-editor-routing' else 'docs/qa/rebase-conflict-menus-native-2026-10-14.swift' if case == 'rebase-conflict-menus' else 'docs/qa/conflict-review-native-2026-10-14.swift' if case == 'conflict-review' else 'docs/qa/resolve-progress-native-2026-10-14.swift' if case == 'resolve-progress' else 'docs/qa/primary-dialog-captures-2026-10-14.swift' if case == 'primary-dialog-captures' else 'docs/qa/rebase-session-refresh-native-2026-10-14.swift' if case == 'rebase-session-refresh' else 'docs/qa/log-changed-files-native-2026-10-14.swift' if case == 'log-changed-files' else 'docs/qa/history-workflows-native-2026-10-14.swift' if case == 'history-workflows' else 'docs/qa/bisect-progress-native-2026-10-14.swift' if case == 'bisect-progress' else 'docs/qa/worktree-progress-native-2026-10-14.swift' if case == 'worktree-progress' else 'docs/qa/progress-auto-close-native-2026-10-08.swift' if case == 'progress-auto-close' else 'docs/qa/stash-save-progress-native-2026-10-08.swift' if case == 'stash-save-progress' else 'docs/qa/switch-progress-native-2026-10-08.swift' if case == 'switch-progress' else 'docs/qa/reset-progress-native-2026-10-08.swift' if case == 'reset-progress' else 'docs/qa/local-command-progress-native-2026-10-14.swift' if case == 'local-command-progress' else 'docs/qa/rebase-references-native-2026-10-14.swift' if case == 'rebase-references' else 'docs/qa/log-reference-navigation-native-2026-10-14.swift' if case == 'log-reference-navigation' else 'docs/qa/working-tree-scope-native-2026-10-14.swift' if case == 'working-tree-scope' else 'docs/qa/advanced-list-consumers-native-2026-10-14.swift' if case == 'advanced-list-consumers' else 'docs/qa/comparison-launch-native-2026-10-14.swift' if case == 'comparison-launch' else 'docs/qa/commit-file-workflows-native-2026-10-14.swift' if case == 'commit-file-workflows' else 'docs/qa/log-progressive-rows-native-2026-10-14.swift' if case == 'log-progressive-rows' else 'docs/qa/file-list-layout-native-2026-10-14.swift' if case == 'file-list-layout' else 'docs/qa/log-history-stream-native-2026-10-14.swift' if case == 'log-history-stream' else 'docs/qa/submodule-handoffs-native-2026-10-14.swift' if case == 'submodule-handoffs' else 'docs/qa/working-tree-groups-native-2026-10-14.swift' if case == 'working-tree-groups' else 'docs/qa/working-tree-file-menu-native-2026-10-14.swift' if case == 'working-tree-file-menu' else 'docs/qa/lfs-locks-native-2026-10-08.swift' if case == 'working-tree-lfs' else 'docs/qa/working-tree-lifecycle-native-2026-10-14.swift' if case == 'working-tree-lifecycle' else 'docs/qa/ssh-key-import-native-2026-10-14.swift' if case == 'ssh-key-import' else 'docs/qa/worktree-family-native-2026-10-14.swift' if case == 'worktree-family' else 'docs/qa/revision-graph-window-native-2026-10-10.swift' if case == 'revision-graph' else 'docs/qa/settings-family-native-2026-10-13.swift' if case == 'settings-family' else 'docs/qa/ssh-coordinator-native-2026-10-09.swift' if case == 'ssh-coordinator' else 'docs/qa/rebase-row-drag-native-2026-10-13.swift' if case == 'rebase-row-drag' else 'docs/qa/rebase-conditional-native-2026-10-13.swift' if case == 'rebase-conditional' else 'docs/qa/rebase-columns-native-2026-10-13.swift' if case == 'rebase-columns' else 'docs/qa/commit-preferences-native-2026-10-13.swift' if case == 'commit-preferences' else 'docs/qa/log-metadata-native-2026-10-14.swift' if case == 'log-metadata' else 'docs/qa/log-column-layout-native-2026-10-13.swift' if case == 'log-column-layout' else 'docs/qa/reflog-reference-deletion-native-2026-10-13.swift' if case == 'reflog-reference-deletion' else 'docs/qa/reflog-advanced-native-2026-10-13.swift' if case == 'reflog-advanced' else 'docs/qa/reflog-notes-patch-native-2026-10-13.swift' if case == 'reflog-notes-patch' else 'docs/qa/reflog-operations-native-2026-10-13.swift' if case == 'reflog-operations' else 'docs/qa/reflog-table-native-2026-10-13.swift' if case == 'reflog-table' else 'docs/qa/three-pane-endings-native-2026-10-08.swift' if case == 'merge-source' else 'docs/qa/merge-clipboard-native-2026-10-13.swift' if case == 'merge-clipboard' else 'docs/qa/ignore-workflow-native-2026-10-13.swift' if case == 'ignore-workflow' else 'docs/qa/version-combo-native-2026-10-13.swift' if case == 'version-combo' else 'docs/qa/switch-pickers-native-2026-10-09.swift' if case == 'switch-pickers' else 'docs/qa/creation-pickers-native-2026-10-09.swift' if case == 'creation-pickers' else 'docs/qa/add-dialog-native-2026-10-13.swift' if case == 'add-dialog' else 'docs/qa/add-drop-native-2026-10-13.swift' if case == 'add-drop' else 'docs/qa/commit-drop-native-2026-10-13.swift' if case == 'commit-drop' else 'docs/qa/input-hosts-native-2026-10-13.swift' if case == 'input-hosts' else 'docs/qa/input-dialogs-native-2026-10-13.swift' if case == 'input-dialogs' else 'docs/qa/fetch-history-native-2026-10-07.swift' if case == 'fetch-history' else 'docs/qa/remote-dialogs-native-2026-10-13.swift' if case == 'remote-dialogs' else 'docs/qa/file-patches-native-2026-10-13.swift' if case == 'file-patches' else 'docs/qa/bisect-lifecycle-native-2026-10-13.swift' if case == 'bisect-lifecycle' else 'docs/qa/message-spelling-native-2026-10-13.swift' if case == 'message-spelling' else 'docs/qa/git-askpass-native-2026-10-13.swift' if case == 'git-askpass' else 'docs/qa/patch-review-lifecycle-native-2026-10-13.swift' if case == 'patch-review-lifecycle' else 'docs/qa/ssh-authentication-native-2026-10-13.swift' if case == 'ssh-authentication' else 'docs/qa/git-properties-native-2026-10-13.swift' if case == 'git-properties' else 'docs/qa/partial-patch-native-2026-10-13.swift' if case == 'partial-patch' else 'docs/qa/finder-service-grants-native-2026-10-13.swift' if case == 'finder-service-grants' else 'docs/qa/finder-service-grant-worker-native-2026-10-13.swift' if case == 'finder-service-grant-worker' else 'docs/qa/finder-watches-native-2026-10-13.swift' if case == 'finder-watches' else 'docs/qa/finder-watches-capture-native-2026-10-13.swift' if case == 'finder-watches-captures' else 'docs/qa/finder-publication-native-2026-10-13.swift' if case == 'finder-publication' else 'docs/qa/finder-publication-worker-native-2026-10-13.swift' if case == 'finder-publication-worker' else 'docs/qa/finder-events-native-2026-10-13.swift' if case == 'finder-events' else 'docs/qa/repository-browser-table-capture-native-2026-10-13.swift' if case == 'repository-browser-table-captures' else 'docs/qa/repository-browser-table-native-2026-10-13.swift' if case == 'repository-browser-table' else 'docs/qa/repository-browser-lifecycle-native-2026-10-13.swift' if case == 'repository-browser' else 'docs/qa/blame-wrap-native-2026-10-13.swift' if case == 'blame-wrap' else 'docs/qa/blame-wrap-capture-native-2026-10-13.swift' if case == 'blame-wrap-captures' else 'docs/qa/blame-lexilla-native-2026-10-13.swift' if case == 'blame-lexilla' else 'docs/qa/blame-menu-native-2026-10-13.swift' if case == 'blame-menus' else 'docs/qa/blame-file-open-native-2026-10-13.swift' if case == 'blame-file-open' else 'docs/qa/blame-find-native-2026-10-13.swift' if case == 'blame-find' else 'docs/qa/blame-source-editor-native-2026-10-13.swift' if case == 'blame-source' else 'docs/qa/blame-source-capture-native-2026-10-13.swift' if case == 'blame-captures' else 'docs/qa/sync-hooks-native-2026-10-14.swift' if case == 'sync-hooks' else 'docs/qa/stash-restore-native-2026-10-08.swift' if case == 'stash-restore' else 'docs/qa/utility-captures-2026-10-12.swift' if case == 'utility-captures' else 'docs/qa/client-hooks-native-2026-10-12.swift' if case == 'client-hooks' else 'docs/qa/autotext-tester-native-2026-10-12.swift' if case == 'autotext-tester' else 'docs/qa/issue-tracker-captures-2026-10-12.swift' if case == 'issue-captures' else 'docs/qa/issue-tracker-settings-native-2026-10-12.swift' if case == 'issue-tracker-settings' else 'docs/qa/issue-regex-tester-native-2026-10-12.swift' if case == 'issue-regex-tester' else 'docs/qa/svn-native-2026-10-12.swift' if case == 'svn-workflow' else 'docs/qa/commit-progress-native-2026-10-08.swift' if case == 'commit-progress' else 'docs/qa/email-settings-native-2026-10-10.swift' if case == 'email-settings' else 'docs/qa/overlay-settings-native-2026-10-12.swift' if case == 'overlay-settings' else 'docs/qa/external-merge-lifecycle-native-2026-10-12.swift' if case == 'external-merge-lifecycle' else 'docs/qa/tool-settings-native-2026-10-12.swift' if case == 'tool-settings' else 'docs/qa/credential-settings-native-2026-10-12.swift' if case == 'credential-settings' else 'docs/qa/network-settings-native-2026-10-12.swift' if case == 'network-settings' else 'docs/qa/merge-pickers-native-2026-10-09.swift' if case == 'merge-pickers' else 'docs/qa/reference-' + case + '-native-2026-10-09.swift')
        source.write_text('@testable import TurtleGitMac\n' + fixture.read_text().replace('@main struct', 'struct', 1))
        if case == 'working-tree-lfs':
            source.write_text(source.read_text() + '\nstruct WorkingTreeLFSVerification {\n    @MainActor static func main() async {\n        do { try await LFSLocksVerification.main() }\n        catch { fputs("Working Tree LFS regression failed: \(error)\\n", stderr); exit(1) }\n    }\n}\n')
        sources.append(source)
    askpass_window = directory / 'GitAskpassWindow.swift'
    askpass_window.write_text('import TurtleGitCore\n' + (root / 'Sources/TurtleGitGitAskpass/PromptWindow.swift').read_text())
    sources.append(askpass_window)
    if 'svn-workflow' in compiled_cases:
        svn_fixture = directory / 'SVNFixture.swift'
        svn_fixture.write_text((root / 'Tests/TurtleGitCoreTests/GitSVNFixture.swift').read_text().replace('@testable import TurtleGitCore', 'import TurtleGitCore'))
        sources.append(svn_fixture)
        svn_entry = directory / 'SVNEntry.swift'
        svn_entry.write_text(r'''import Foundation
    struct SVNWorkflowVerification {
        @MainActor static func main() async {
            setenv("TURTLEGIT_SVN_TEST_GIT", CommandLine.arguments[2], 1)
            do { try await SVNNativeVerification.verify() }
            catch { fputs("SVN workflow failed: \(error)\n", stderr); exit(1) }
        }
    }
    ''')
        sources.append(svn_entry)
    main = directory / 'Main.swift'
    throwing_cases = {'reset-progress', 'switch-progress', 'stash-save-progress', 'progress-auto-close'}
    branches = '\n'.join(
        '        case "' + case + '": ' +
        ('do { try await ' + name + '.main() } catch { fputs(String(describing: error) + "\\n", stderr); exit(1) }' if case in throwing_cases else 'await ' + name + '.main()')
        for case, name in compiled_cases.items())
    main.write_text('''import AppKit
@_cdecl("turtlegit_reference_batch_main") func bootstrap() -> Int32 {
    NSApplication.shared.setActivationPolicy(.prohibited)
    Task { @MainActor in
        switch CommandLine.arguments[3] {
''' + branches + '''
        default: exit(2)
        }
        exit(0)
    }
    NSApplication.shared.run(); return 0
}
''')
    digest = hashlib.sha256()
    digest.update((platform.machine() + '/macos13/swift5/WMO-Onone/reference-objects-v1').encode())
    digest.update(subprocess.check_output(['xcrun', 'swiftc', '--version']))
    imports = [products / 'TurtleGitMac.swiftmodule', products / 'TurtleGitCore.framework']
    inputs = [*objects, *sources, main]
    for imported in imports:
        inputs += sorted(p for p in imported.rglob('*') if p.is_file() and not p.is_symlink())
    for source in inputs:
        digest.update(source.name.encode()); digest.update(source.read_bytes())
    cache = root / 'build/qa/native-receivers'; cache.mkdir(parents=True, exist_ok=True)
    executable = cache / ('reference-' + digest.hexdigest())
    if not executable.exists():
        staging = directory / 'reference-receiver'
        subprocess.run(['xcrun', 'swiftc', '-whole-module-optimization', '-Onone', '-parse-as-library', '-swift-version', '5',
                        '-target', platform.machine() + '-apple-macos13.0', '-I', str(products), '-F', str(products),
                        *map(str, sources), str(main), *map(str, objects), '-framework', 'TurtleGitCore',
                        '-Xlinker', '-rpath', '-Xlinker', str(products), '-Xlinker', '-e', '-Xlinker', '_turtlegit_reference_batch_main',
                        '-o', str(staging)], cwd=root, check=True, timeout=300)
        staging.replace(executable)
        print('Reference receivers linked once to the current Debug app objects.', flush=True)
    else:
        print('Reusing reference receiver for unchanged objects/modules/fixtures/toolchain.', flush=True)
    environment = os.environ.copy()
    environment.update(DYLD_FRAMEWORK_PATH=str(products), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    for key in ['GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL']:
        environment.pop(key, None)
    for index, git in enumerate(args.git or [Path('/usr/bin/git')]):
        for case in args.only or [case for case in CASES if case not in ['working-tree-lfs', 'primary-dialog-captures', 'finder-service-grant-worker', 'finder-watches-captures', 'finder-publication-worker', 'issue-captures', 'utility-captures', 'blame-captures', 'blame-wrap-captures', 'repository-browser-table-captures']]:
            # Unix-domain agent sockets have a platform path-length limit.
            fixture = Path(fixture_lifetimes.enter_context(tempfile.TemporaryDirectory(prefix='tg-ssh-', dir='/tmp'))) if case == 'ssh-coordinator' else directory / (str(index) + '-' + case)
            fixture.mkdir(exist_ok=True)
            command = [str(executable), str(fixture), str(git.absolute()), case]
            print('Checking ' + case + ' with ' + str(git), flush=True)
            case_environment = environment.copy()
            if case in ['settings-family', 'network-settings', 'credential-settings', 'issue-tracker-settings', 'issue-captures']:
                case_environment['GIT_CONFIG_GLOBAL'] = str(fixture / 'global.config')
                case_environment['XDG_CONFIG_HOME'] = str(fixture / 'xdg')
            receiver = subprocess.Popen(command, cwd=root, env=case_environment, start_new_session=True)
            try:
                code = receiver.wait(timeout=300)
                if code: raise subprocess.CalledProcessError(code, command)
            finally:
                cleanup['close_receiver'](receiver)
                print('Owned receiver reaped: ' + str(receiver.pid), flush=True)
