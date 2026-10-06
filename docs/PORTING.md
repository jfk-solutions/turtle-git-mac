# TurtleGit for Mac — full port tracking

*A macOS fork of TortoiseGit*

The target is complete behavioral parity, with native macOS windows and Finder
integration. This first implementation establishes the architecture and common
workflows. It does **not** represent the complete port or reproduce all upstream
windows. No item is complete merely because its underlying Git command runs.

Format Patch's three export modes and no-prefix command are implemented in the
repository layer with seven tests, including binary mail patch
application. Its native dialog, progress and mail handoff compile; native runtime
and signed sandbox verification remain pending. See
[FORMAT-PATCH-PARITY.md](FORMAT-PATCH-PARITY.md) for the audited controls and scope.

## Audited baseline

Worktree creation, listing, locking, unlocking, removal and pruning now have a
repository-layer port with disposable-repository tests. New Worktree has a native
dialog and create routing with actual model verification. Worktree List and
management menus now have native implementation and actual model verification;
full native/signed acceptance remains pending. See
[WORKTREE-PARITY.md](WORKTREE-PARITY.md).

Upstream: https://github.com/TortoiseGit/TortoiseGit

Commit: `7338078f8ddd924b8cddee35f512f2286072136d`.

The checked-in inventory covers 3,277 tracked entries and 129 dialog resources.
`upstream-files.csv` maps paths, blob hashes, review status, replacement and notes.
`upstream-dialogs.csv` lists dialog resources and captions, including the settings
pages and helper applications. Gitlinks must be recursively audited before using
those dependencies. Resources such as menus, icons, accelerators and strings also
require review; a dialog count is not a count of all upstream UI.

## Architecture replacements

| Upstream component | macOS replacement | Current state |
| --- | --- | --- |
| TortoiseProc / MFC | SwiftUI windows, AppKit text views and file dialogs | First status, commit, log and operation views |
| src/Git | TurtleGitCore repository actor and installed Git | Basic status, mutation and patch operations |
| TortoiseShell / COM | Finder Sync extension and URL routing | Compiles; signed end-to-end behavior unverified |
| TGitCache | App Group snapshot, directory badge aggregation | Active repository polling; independent daemon pending |
| TortoiseMerge | Native three-pane UTF-8 conflict editor | Partial stage extraction, block choices and guarded saves; full view/menu parity pending. See TEXT-MERGE-PARITY.md |
| TortoiseGitBlame | Historical annotation reader and native annotated source window | Partial columns, age colors, Find/Go To Line and origin-aware Log; full menus, syntax, encodings and signed acceptance pending. See BLAME-PARITY.md |
| TortoiseIDiff | Native image comparison window | Pending |
| TortoiseUDiff | Native patch window with highlighted text, find, appearance settings and printing | Partial File/View/menu behavior; full parity and signed acceptance pending |
| SshAskPass / TortoisePlink | Git helpers, Keychain and OpenSSH | Existing helper configuration only |
| GitWCRev / COM | Portable revision/template CLI and macOS automation | Pending; COM must be replaced |
| TortoiseGitSetup | Signed app, extension registration, notarized distribution | Pinned universal Git build/embedding added; signed runtime and distribution acceptance pending |
| Languages / ResText | String catalogs and native localized resources | Pending |

## Behavioral parity backlog

| Workflow | First-pass implementation | Remaining upstream behavior |
| --- | --- | --- |
| Check for modifications | Native standalone Working Tree dialog; columns, scope/filters, statistics, dates, sorting, diff export and basic menus | Full menus, remote checks, progress/cancellation and persistent preferences; see STATUS-PARITY.md |
| Add | Native scoped checked list, ignored defaults, direct-file progress route, original icons/watermark, tracked history/Blame/base, unified diff, two-file comparison and temporary restoration/Revert menus, cancellable private-index add and index-only executable/symlink post-actions | Full menus, native visual/gesture/signed acceptance; see ADD-PARITY.md |
| Commit | Native checked-file dialog; optional three-state staging; amend, author, sign-off, statistics | Unsupported partial-stage file types, full history/completion, hooks UI, issue trackers, remaining action menu |
| Log | Separate native three-pane window; graph, refs, message/files/line counts, selectable message/identity/revision search and date filters, load more, comparisons and revision actions | Working-tree row, actions column, branch/ref chooser, full search syntax/fields, walk/view controls, statistics, multi-revision file union, remaining context commands; see LOG-PARITY.md |
| Diff | Index/worktree/commit textual patches | Side-by-side, syntax highlighting, binary/image handling, external tools |
| Clone | Native Git/SSH/SVN option groups, URL/destination history and browsing, real Git clone tests, native shallow selected-branch/custom-origin clone and Log handoff | Full progress/cancellation, native picker/Cancel QA, authentication, real SVN/LFS runtimes, signed sandbox and bare clone adoption QA; see CLONE-PARITY.md |
| Init | Native upstream Bare/text/buttons, .git default, destination warnings, real Git tests and normal/bare creation; bare workspace/Log | Picker confirmation, immediate adoption/recents, full bare menu behavior and signed integration; see INIT-PARITY.md |
| Fetch | Native remote/URL and three-state tags/prune, remote branch browser, shallow depth; real Git and native fetch checks | Full Rebase post-operation choices, settings/history, progress, authentication and broader UI QA; see FETCH-PARITY.md |
| Rebase | Native branch/action/list/tabs window; real Start/Skip and recovered Edit/Amend; tested persistent backend | Fetch/Pull handoffs verified; full recovery/advanced UI and conflict controls pending; see REBASE-PARITY.md |
| Pull | Native shared options window, squash/no commit and fast-forward choices; Git integration and native fast-forward/error checks | Interactive rebase, progress, full recovery and broader native QA; see PULL-PARITY.md |
| Push | Native upstream control order, branch/tag scope, remote/URL, force/lease, tags, upstream, recursion, server option; local Git tests and native branch/tag pushes | Full choosers/settings, progress, cancellation, authentication and broader UI QA; see PUSH-PARITY.md |
| Switch/Checkout | Native branch/tag/commit rows, create/force/merge/tracking/override options, real Git checkout tests | Complete choosers, progress and broader native QA; see SWITCH-PARITY.md |
| Branch / tag | Native name/revision/options/message controls; descriptions, annotated tags, optional checkout, force and tracking | Full choosers, signing prompts and broader native QA; see BRANCH-TAG-PARITY.md |
| Merge | Native revision/options/message window; real Git option/conflict tests and native No Commit → staging Commit verified | Message history, full choosers, progress/post-actions and native conflict recovery; see MERGE-PARITY.md |
| RefLog | Native five-column list, reference selector, Search, stash inspection/Apply and guarded Drop/Clear | Full context menus, general reflog deletion, persistence and broader native QA; see REFLOG-PARITY.md |
| Stash | Native Save options/warning plus direct Apply/Pop result prompts and Working Tree handoff; Git effects verified | RefLog list/inspection/selected Apply and guarded Drop/Clear now implemented; branch from stash, full progress/post-actions and broader native QA pending; see STASH-PARITY.md |
| Finder | Original icons, separate menu preferences, cache badges, selection dispatch, scoped Diff/Log, source file/folder/selection clauses, direct two-file comparisons, recursive foreground submodule caches and root Rename/Remove, folder creation entries and targetless toolbar creation routing | Signed QA, remaining shell commands, watched-root management, cache daemon/FSEvents |
| Settings | Native 52-row Advanced draft editor with source defaults/validation and Apply/Cancel; Appearance and partial Merge Editor General: saved indentation and line-number defaults with Apply/Cancel | Remaining merge General/Colors, Git identity, tools, overlays, dialogs, hooks, credentials, networking, localization |
| Rename | Native source/name/browse/OK/Cancel, original artwork, versioned-file menus and guarded Git mv; mixed-file effects verified | Native browse, post-close restoration, submodules, shared-dialog consumers and signed Finder QA; see RENAME-PARITY.md |
| Delete / keep local | Native confirmation, per-item Remove/Ignore/Abort, original icon and guarded Git removal; retained-copy commits/amendments tested | Native normal-delete execution, submodules, complete Finder conditions and signed QA; see REMOVE-PARITY.md |
| Ignore | Native five-radio upstream layout, original icon, app/Finder name/extension actions and Delete-and-ignore keep-local flow; real Git and native checks | Full menu conditions, native recovery/No/refresh and signed permissions; see IGNORE-PARITY.md |
| Reset | Native upstream revision/type groups, Log dispatch and initialized submodule reset/resume; real modes and native Mixed/Soft verified | Full chooser/diff-list, progress, native Hard/recovery and signed QA; see RESET-PARITY.md |
| Delete/modify conflict | Native fourteen-control conflict layout, keep/delete/Abort and side Log; exact Git effects and native keep/comparison/history verified | Full diff editor, Created/rebase/error/native Delete QA, parent restoration and signed scope; see DELETE-CONFLICT-PARITY.md |
| Resolve | Native checked list, current/mine/theirs, original icon and app/Finder dispatch; real Git and native checked-current/Cancel verified | Full conflict editor, remaining submodule chooser edge cases, progress, signed Finder and broader QA pending; see RESOLVE-PARITY.md |
| Other commands | Log-selected reset, revert without commit and cherry-pick | Full options, conflict continuation/abort, resolve, bisect, clean, export |
| Patch workflows | Native Format Patch dialog and three repository export modes; progress and mail handoff compile | Native export/mail acceptance, apply patches, am continuation/abort, full review and email workflows |
| Repository Browser | Native lazy folder tree, pinned revisions, sortable Name/Extension/Size, historical file menus, marked comparisons and historical Revert, pinned child Log and historical drag representations | Multi-file Revert acceptance, actual Finder drops, broader submodule acceptance, dark/native action coverage and signed scopes; see REPOSITORY-BROWSER-PARITY.md |
| Advanced repositories | Native New Worktree and Worktree List with create/lock/unlock/remove/prune; partial submodule workflows | Native column gestures/appearance, Finder drop creation, native/signed acceptance, full submodules, git-svn and LFS |
| Helper apps | Partial native Blame, text Merge and unified Diff windows | Full helper parity, image diff, revision graph, askpass and revision/template tools |

## Porting method

1. Review a file and its related call sites, resource IDs, tests and documentation.
2. Record whether it is portable, requires a framework replacement, is an external
   dependency, or is Windows infrastructure with a documented macOS equivalent.
3. Implement its behavior in the named macOS module. Shared upstream logic can be
   retained as C/C++ where that reduces divergence; Windows UI is rewritten.
4. Compare native dialogs against upstream controls, options, defaults, shortcuts,
   error behavior and selection semantics. Preserve familiar workflow ordering and
   status colors while using macOS layout, menus and accessibility.
5. Exercise real Git fixtures for expected results and failure/conflict cases.
6. Mark a feature parity-complete only after all relevant source/resource mappings,
   behavior tests and UI acceptance checks pass. Platform exclusions need explicit
   rationale and a replacement or an acknowledged gap.

Every unreviewed file remains pending. The initial mapped command and dialog rows
are marked **partial**, not complete. A broad Swift rewrite still needs this
source-by-source audit; copying C++ files alone would not establish parity.

## Verification records

Recent Add receiver checks and unsigned build/package results are recorded in
[Add history](qa/add-history-2026-10-06.json) and
[Add missing-file comparison](qa/add-missing-pair-2026-10-06.json) and
[Add current-column clipboard](qa/add-current-column-2026-10-06.json) and
[Add unified diff](qa/add-unified-2026-10-06.json) and
[Add restoration copies](qa/add-restore-2026-10-06.json) and
[Add Revert](qa/add-revert-2026-10-06.json) and
[Revert progress table](qa/revert-table-2026-10-06.json) and
[Add index flags](qa/add-flags-2026-10-06.json) and
[Log search fields](qa/log-search-2026-10-06.json) and
[Log subject and case search](qa/log-search-case-2026-10-06.json) and
[Log filter selection](qa/log-search-selection-2026-10-06.json).
These checks do not establish full application parity, displayed-window acceptance,
signed Finder activation or distribution readiness. Workflow-specific parity files
record the remaining requirements.

## Earlier validation milestones

The following records describe earlier milestones. Test and icon counts belong to
those milestones; use the recent QA records for current validation scope.

`swift test` covers raw path parsing, renames/conflicts, stage/unstage including an
unborn branch, multiline commits and log parsing, working-tree diffs, literal
wildcard filenames, ignored files, linked worktrees, large output without deadlock,
failure propagation, blank message rejection, directory badge aggregation and
branch/tag/switch/merge/rebase argument compatibility with Git.

Manual UI checks on a disposable repository verified the branding, status list,
selected-file diff and history. They also caught and fixed an absent shared-cache
directory failure and a commit-layout issue that squeezed the file list.

The application, shared framework and embedded Finder extension compile using
`xcodebuild` with signing disabled. These checks do not establish Finder activation,
signed App Group access, accessibility, full UI correctness, credential prompts,
Intel compatibility or upstream parity.

## App Store preparation

Saved security-scoped repository permissions and a separate sandboxed AppStore
configuration have been added. The runtime selector requires a bundled Git engine
for that configuration. The pinned runtime build includes HTTPS helpers and source
material. See `DISTRIBUTION.md` for runtime acceptance, signing,
worktree permissions and license gates. These changes do not narrow the full-port
objective or establish App Store readiness.

The current Swift package builds and 78 tests pass, including topological graph
continuity, root/merge/rename file statistics, annotated tag resolution, commit
search, and decoding all 37 original upstream icons. Finder source type-checks
with application-extension restrictions. The local Xcode bundle build is currently blocked
by a missing CoreSimulator.framework in the Xcode installation. GitHub's macOS CI
successfully compiled the app and embedded Finder extension in both Debug and
sandboxed AppStore configurations at `1b66080`. Bundle validation confirmed all
32 original icons, their hashes and license, the shared framework, and the embedded
Finder extension in both configurations. The [CI run](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/37120088567)
also passed the 24 Swift tests. Signed Finder appearance remains unverified.

Finder requests now carry all selected paths as repeated URL fields, preserving
literal filename characters. One security grant must contain every item; each
item's containing repository is checked before replacing the current session or
running a command. Mixed and nested repository selections are rejected. Selected
folders expand to changed rows using path component boundaries. Finder Diff uses
the requested paths even when no status rows exist, and Log accepts multiple path
filters with a Show Whole Project checkbox. The commit dialog now keeps checked files separate from highlighted rows.
Checkbox mode commits selected working-tree files; staging mode commits the index.
Other upstream shell commands remain pending. New tests cover URL parsing, legacy requests, malformed input, directory
selection, literal multi-path history, and clean-file diff isolation.

The Commit window now follows the upstream message-above-file-list arrangement,
with category check links, original status icons, line counts, amend, author and
sign-off controls. Its optional staging support uses native three-state checkboxes
in the same file list. Git integration tests cover unchecked index preservation,
unborn commits, staged rename/deletion, amend with no checked files, custom author,
sign-off, partial index contents, and rejection by a pre-commit hook. A native UI
commit on disposable sample data committed only README.md and left the unchecked
Sources/Repository.swift change staged. Native staging checkboxes, mixed-state rendering, stage/unstage of an unversioned
file and an index commit preserving later working-tree edits were also exercised
on disposable sample data. The right-hand patch window now stages/unstages selected lines and hunks in
tracked UTF-8 text files, with native UI and real Git integration verification. See COMMIT-PARITY.md for remaining parity.

Submodule conflict chooser now has native Base/destination groups and choice
actions, with 167 passing tests and actual light/dark captures. See
SUBMODULE-CONFLICT-PARITY.md for the remaining full-port requirements.

Resolve now matches upstream file-to-gitlink checkout and failed submodule
removal Delete/Abort choices, with native Abort/Delete and recoverable Trash
verification. Remaining type transitions, registered/multi-item removal and full
progress still require audit.

Text merge source panes now align base removals, additions, conflicts and gaps
with upstream light/dark colors and original source line numbers. The latest
full suite passes 180 tests; alignment tests reconstruct exact source contents
over exhaustive and seeded Unicode/CRLF cases. Actual native captures verify
the palette and layout. Full libsvn segmentation parity, source scrolling QA
and broader keyboard acceptance remain incomplete; see TEXT-MERGE-PARITY.md.

The text editor's source context menus now expose Use this whole file with
undoable original-stage replacement. Native Mine/Theirs, keyboard Undo/Redo and
unsaved-close Cancel are verified. Reload now exposes existing stage reload
with original artwork and history reset; its native dirty prompt/Cancel are verified, while confirmed reload remains
pending. Full source-block selection and upstream EOL handling are still partial.

The merge Reload prompt now includes Save before Reload. A real-Git regression
test verifies Unicode/CRLF/EOF draft saving followed by conflict regeneration
without changing unresolved stages or unrelated data. Native Save and Reload
saved exact Mine contents; final view/history acceptance remains pending.

EOF conflict choices now retain original missing-final-newline metadata across
saves, with five real-Git ending combinations and native combined-choice Save
verification. Upstream EOL normalization and native CRLF/Undo/resolve coverage
remain partial.

The text merge result now offers the upstream nine-style line-ending submenu
with reversible conversion. A shared UTF-16 scanner fixes CRLF marker detection
and caret line numbers. Native CRLF → LF, Undo/Redo and unresolved Save warning
were verified; complete EOL/encoding metadata and exotic native combinations
remain partial. See TEXT-MERGE-PARITY.md.

The text merge context menu now includes upstream leading tabs/spaces
conversion and Trim right, with single-step Undo and conditional availability.
Native conversion, Undo and exact Unicode/CRLF Save bytes were verified.
Global tab-width preferences, EditorConfig and locale-specific Unicode trim remain
pending. See TEXT-MERGE-PARITY.md.

The merge editor now has independent 1/2/4/8 tab-width menus in each pane.
Native width changes preserved clean state and Undo history; merged-result
conversion and Save bytes at width eight were verified. Global persistence,
global insertion-mode preferences and EditorConfig remain pending.

Merge pane menus now include Tab/Space and Smart tab char. Native Space
insertion, nearby-tab Smart choice, multiline Tab/Shift-Tab, Undo and exact Save
bytes were verified. Global preferences, EditorConfig, precise partial-column
selection restoration and broader key/view behavior remain pending.

Advanced Settings now has a native Name/Value editor for all 52 registered
source settings, with source defaults, deferred Apply and blank-value reset.
Most setting consumers, the complete settings host and native/signed acceptance
remain pending. See [ADVANCED-SETTINGS-PARITY.md](ADVANCED-SETTINGS-PARITY.md).
