# Log Messages parity

The implementation target is the actual TortoiseGit Log Messages dialog and its
selection-dependent context menus. Native macOS controls retain the three-pane
arrangement and familiar command order. The initial sidebar log table was removed.

## Specification

Audited baseline: `7338078f8ddd924b8cddee35f512f2286072136d`.

- `src/Resources/TortoiseProcENG.rc`, `IDD_LOGMESSAGE`: filter row, three panes,
  path filter, project/all-branches toggles and footer controls.
- `src/TortoiseProc/LogDlg.cpp` and `LogDlg.h`: selection, changed files and controls.
- `src/TortoiseProc/GitLogListBase.cpp`: columns, graph painting and revision menus.
- `src/TortoiseProc/GitLogListAction.cpp`: revision operations.
- [Upstream Log Messages manual](https://tortoisegit.org/docs/tortoisegit/tgit-dug-showlog.html).

## Implemented and checked

- Separate resizable native window with three resizable panes.
- Compact graph before SHA-1/message/author/date; continuous lanes based on real
  parent hashes. Circles mark ordinary commits, squares mark merges/branch points.
  Topological order avoids sorting rows into a misleading graph.
- HEAD in bold; active branch red, other local branches green, remote branches
  orange and annotated/lightweight tags yellow.
- Full selected commit message, hash, author/email, date and parents.
- Changed paths, extension, action, added/removed counts; binary counts are `–`.
  Root commits and merge first-parent changes are handled explicitly. NUL parsing
  preserves tabs, newlines and Unicode filenames and both sides of a rename.
- Case-insensitive fixed-string commit-message search, optional date range,
  all branches, path filtering in the changed-file pane and loading 200 more rows.
- Single-revision/base and working-tree unified diff; two-revision unified diff.
  Double-click a revision opens the comparison. Patch text remains selectable.
- Hash, message and log-details copy actions; changed-path copy and comparisons.
- Branch and lightweight tag creation at a selected hash, detached checkout,
  soft/mixed/hard reset, revert without committing, and single-parent cherry-pick.
  Each operation opens a native dialog capturing the exact selected revision.
  Reset now uses the full revision/type window; see [Reset parity](RESET-PARITY.md)
  for Git effects, native Mixed checks and remaining chooser/progress work.
- Conflict-side Show log can bound history to a verified commit and path; the
  incoming-side native handoff was checked. All Branches retains that bound.
- Original upstream colored command icons in revision and changed-file menus.

Tests cover graph continuity at merges and branch points, octopus/disconnected
histories, real root/merge/rename stats, binary and unusual paths, full commit
messages, annotated tags, search and limits. Native preview QA checked selection,
merge graph, file stats and double-click diff with disposable sample repositories.

## Still partial

| Area | Remaining behavior |
| --- | --- |
| Columns | Actions icons, column chooser/persistence, optional email/committer/bug/SVN columns |
| Graph | Working-tree pseudo revision, collapse/expand, hidden refs and all merge parent choices |
| References | Branch/ref chooser, remote ref deletion and tracking menus |
| Search/filter | Author/email/hash/path search modes, jump next/previous, whole-project/folder history, regex and highlighting |
| Files | Multi-revision union, multi-file diff, file log/blame, restore, save/export revision, open/editor/Finder actions |
| Revision menus | Repository browser, rebase onto selection, edit notes, export, format patch, bisect, squash, ref containment/search |
| Mutations | Full branch/tag options, checkout branches, mainline choices for merge revert/cherry-pick, multi-commit operations, conflict continue/abort |
| Footer | Statistics, walk behavior, View options and upstream settings persistence |
| Comparison | Native side-by-side/three-way editor, merge combined diffs and external tool configuration |
| Accessibility | Full VoiceOver acceptance, keyboard shortcuts and focus parity |

These source mappings remain partial. A populated menu or a working Git command
does not establish complete upstream parity.

## Icon provenance

Artwork is copied unchanged from the pinned upstream resource directory. The
shared `Icons` resource folder contains the original license and a source-path and
SHA-256 manifest. We choose its GPL alternative. Both Xcode's shared framework and
Swift Package resources carry the artwork. AppKit reads the multi-resolution ICO
and renders 16-point colored menu icons, without template tinting for colored artwork. The monochrome cherry-pick glyph
uses native template tinting for light/dark contrast. Finder uses
upstream XPStyle status artwork; signed Finder visual QA remains pending.

Finder file/folder requests now scope history to all selected paths. The native
Show Whole Project checkbox removes that scope; reopening Show Log from Finder
restores the requested selection. Requests for the repository root show its full
history. The full upstream folder-history controls and rename-following history
remain pending.

Push from a single log revision now opens the separate native Push options window
with that exact hash and the original Push icon. The window builds successfully;
this specific Log handoff still needs native interaction QA. See PUSH-PARITY.md.

## Commit revision chooser

Commit's Pick commit hash/message commands reuse this window as a native sheet.
Selection mode adds Cancel and enables OK only for one revision when loading has
finished, following upstream `EnableOKButton`. Normal Log's OK still closes the
window. Working-tree pseudo revisions are excluded; the current implementation
has no such row in either mode. Native Commit QA verified single acceptance,
multiple-selection rejection, no-match search rejection and cancellation.
See COMMIT-PARITY.md for insertion and Git-state evidence. This mode does not
establish completeness of the shared Log controls or mutation menus.

## Native comparison routing follow-up

Normal repository Log revision menus now open the retained Changed Files window
for working-tree, previous-revision and two-revision comparison. A root commit
uses the empty tree; a merge uses its first parent. Unified diff remains its
separate menu action. One native test verified Log → Changed Files → ordinary
two-pane file viewer; HEAD, index and working contents stayed unchanged and the
QA process exited. Root/two-revision native variants, file-level comparison
routing and history-picker comparison factories remain pending. See
[comparison parity](SUBMODULE-DIFF-PARITY.md) for inline character/word display
and remaining fidelity differences.

## Changed-file native comparison routing

Reviewed `CGitStatusListCtrl::StartDiff`, `StartDiffWC` and double-click routing
at upstream commit `7338078f8ddd924b8cddee35f512f2286072136d`. Log's changed-file
Compare with base and double-click now open retained native two-pane viewers;
Compare with working tree uses the selected historical revision and current
disk contents. The separate unified command uses the original unified-diff icon
and retains its patch sheet. File comparison commands are disabled in history
pickers without a comparison factory. Multi-selection dispatch opens one window
per selected path, with a shared pinned comparison range.

Selected-file snapshots retain rename source paths, added/deleted empty sides
and gitlink routing. Unchanged selected files still open a viewer. For working
comparisons, actual disk existence determines absence: a file left on disk after
an index deletion must display its contents rather than an empty destination.
Historical revisions are pinned before tree inspection. Literal path validation
and NUL-delimited tree lookup preserve Unicode/newline/pathspec-looking names.
Missing paths on both sides produce no file window; directories outside an
identified gitlink are rejected.

One real-Git test verifies renamed and unchanged comparisons, duplicate old/new
path selection, absent paths, working contents after index deletion, actual file
deletion and path escape rejection. It checks exact bytes and unchanged indexes.
One native process verified root-commit file double-click: the base was empty,
the destination contained exact committed bytes, and editing was disabled.
The app was quit immediately afterward; process absence and unchanged fixture
HEAD, index and working bytes were verified.

The changed-file list still shows merge changes against the first parent.
Upstream per-parent rows and combined historical merge display remain pending;
this change does not claim complete merge comparison parity. Native context
menu/working/multi-file/submodule acceptance, picker integration, signed scope,
file log/blame, export and the other advanced file commands remain incomplete.

Validation: all 259 Swift tests passed. Unsigned Debug and App Store builds,
both bundle audits and the static Pages build passed. The App Store audit
exercised universal Git 2.55.0 local operations and checked 11 Mach-O files,
the Finder extension, licenses and 61 original icons. Signed Finder/sandbox
acceptance and App Store approval remain unverified.
