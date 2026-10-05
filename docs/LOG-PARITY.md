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

## File history and historical Save As follow-up

Reviewed upstream file-list Show Log/Show Log of Old Name, FileSaveAs and the
single-file/deleted/directory menu gates at commit
`7338078f8ddd924b8cddee35f512f2286072136d`. Log's file menu now offers Show log
at the selected revision and, for renamed paths, Show log of old name without
the selected-revision endpoint. Both use retained native path-scoped Log windows
and the original log icon. Pickers without a file-history factory disable these
actions. Native QA verified the selected-file endpoint and loaded history.

Save revision to uses the original Save As icon and a native NSSavePanel with a
base-name/short-hash/extension suggestion. The action is hidden for deleted files
and gitlinks. Commit-history file rows now include raw-mode metadata, so gitlinks
are reliably identified. The core historicalFile method pins the commit and
reads exact blob bytes; it rejects missing/escaping paths and gitlinks without
checkout or index writes. Export writes the captured Data atomically to the
panel-selected destination. Symlink blobs export literal target bytes as a file.

A new real-Git test checks binary bytes, UTF-8 BOM, CRLF/no-final-newline text,
symlink targets, current working-file preservation, pinned revision and exact
index preservation. The submodule test additionally verifies gitlink file-row
metadata and export rejection.

At that audit step, native Save acceptance remained **pending**: three sequential QA instances
opened the panel with the correct suggested revision filename, but Save and
New Folder remained disabled. Clearing the read busy state before panel display
and explicitly allowing data/other file types did not establish a working save.
Each panel was cancelled; no export was created. No root cause is claimed.
All three processes were quit and absence verified; fixture HEAD, index and
source bytes remained unchanged. Further Save-panel validation investigation is
required before claiming this workflow works natively. Old-name/rename, binary,
deleted/submodule menu gates and signed sandbox acceptance also remain pending.

The full Swift suite passed all 260 tests before the final native panel-state
adjustments; the final Swift application build passed after those adjustments.
Full Log/file-list parity remains incomplete, including per-parent merge rows,
Blame, revision-file Open/editor actions, multi-file folder export and restoration.

Final unsigned Debug and App Store builds, both bundle audits and the Pages
build passed. The App Store audit verified universal Git 2.55.0 local operations,
11 Mach-O files, the Finder extension, licenses and 61 original icons. These
checks do not establish native Save success, signed scope or App Store approval.

## Save-panel control check and clipboard follow-up

Historical Save presentation now belongs to LogWindowController. The model
reads and captures the pinned content/short hash, then the controller presents
AppKit UI on the next main-queue turn after context-menu tracking. File types
use the suggested extension where known and allow other types. This improves
presentation ownership but is **not** claimed as a fix for disabled Save.

A single subsequent QA process checked both Log historical Save and the
previously accepted two-pane viewer Save As. Both showed disabled Save/New
Folder controls in the same process. Both were cancelled, and the app was quit
with process absence and unchanged fixture HEAD/index/working bytes verified.
The disposable bundle has no sandbox entitlements restricting writes; system
Open/Save panel-service errors were observed. The broader reproducible failure
is not specific to Log's model handler. Its cause remains unproven, and current
native Save acceptance remains pending for both workflows. Previous successful
viewer-export acceptance remains a historical result, not proof for this run.

The Log file clipboard submenu now offers full paths, relative paths, file/
folder names and all displayed file information, with original copy artwork.
It uses visible selected rows in table order; all information reuses the tested
ComparisonFileList tab-delimited path/extension/status/line-count payload.
Gitlinks have blank extensions through shared mode-aware metadata. Path and
line-count text use native primary color when selected, retaining blue when
unselected. These clipboard/contrast changes require native acceptance; no
additional test process was launched for them.

Validation for this UI follow-up: Swift build and all 12 targeted
ComparisonFileList/RevisionComparison tests passed. The prior full 260-test
result remains recorded above; the entire suite was not repeated for these
UI-only changes. Final unsigned Debug/App Store builds, both bundle
audits and the static Pages build passed. The App Store audit verified the
universal Git 2.55.0 runtime/local operations, 11 Mach-O files, Finder extension,
licenses and 61 original icons. Native clipboard and signed
execution remain pending.

## Historical Blame handoff

The single non-deleted, non-submodule changed-file menu opens the native Blame window
at the selected revision, with original Blame application artwork. Native root
and renamed-file history handoffs were checked; full Blame menus, editor layout,
encodings and Finder routing remain pending. See [Blame parity](BLAME-PARITY.md).

## Full revision clipboard details

Log now uses the shared pinned-commit reader for Full log details. It includes
revision, author/email/date, full subject/body/trailers, notes, annotated-tag
contents and changed paths, including old rename names and every merge parent.
Full log details without changed paths retains the metadata, notes and tags while
omitting the path section, matching upstream's two full-information choices.
Multiple selected revisions are captured in visible table order before reading.

The read runs asynchronously with a progress indicator and the retained repository
access lease. Closing or reloading Log, or choosing a newer clipboard command,
invalidates the pending copy. No partial multi-revision text is copied on failure.
The output uses LF, ISO author dates and raw Git annotated-tag text; localized
upstream date preferences and tag presentation remain pending, as described in
[Blame parity](BLAME-PARITY.md). Fast paste before the read finishes can still see
the previous clipboard; the progress indicator identifies the pending operation.

Native QA selected two adjacent revisions and verified their order through paste
into the Log search field. Full output contained both messages, the note, tag and
both path sections. The path-free command retained both messages, the note and tag
and omitted both path sections after its read completed. The one QA app was quit
immediately afterward; no TurtleGit app process remained, and fixture HEAD, index
and working source matched their baseline. Overlapping-request cancellation,
window-close cancellation and signed sandbox acceptance remain pending.

Focused GitBlame/TextConflict tests passed. The existing full 270-test result is
recorded in Blame parity; the full suite was not repeated for this clipboard
option/UI change. An existing compiler warning in conflict-end parsing was removed
by dropping redundant nil comparisons after optional bindings; the existing
conflict parser tests passed with that cleanup.

Final unsigned Debug/AppStore builds passed without compiler warnings. Both bundle
audits passed with the Finder extension, licenses and 62 upstream icons; the
AppStore audit verified universal Git 2.55.0, 11 Mach-O files and local operations.
The static documentation build passed, and the existing public Pages root returned
HTTP 200 with the TurtleGit title. This verifies site availability, not deployment
of this commit or signed App Store acceptance.


## Historical Save As native acceptance recheck (2026-10-05)

A fresh disposable preview of `6c7be1a` opened Log's selected-file Save revision to
panel with Save enabled and the upstream basename/short-hash/extension suggestion.
Go to Folder selected a separate existing output folder, and Save created
`source-e9cae95.txt`. Its 30 bytes matched the pinned commit blob exactly, including
UTF-8 BOM, CRLF and no final newline. Deliberately different staged and later
working contents remained unchanged, as did HEAD and the complete raw index.
The byte hashes and observed workflow are recorded in
[the native QA result](qa/historical-save-2026-10-05.json).

No application code change was needed to make this run succeed. The earlier
disabled-panel observations remain valid historical failures; this acceptance
recheck does not establish their root cause or prove they cannot recur. It resolves
the current native text-file Save acceptance gap only. Binary, symlink, deleted/
submodule gates, overwrite/cancel, old-name variants, signed sandbox destination
scope and a fresh two-pane viewer Save As check remain pending.

The documentation screenshot shortcut did not create an image, so no new screenshot
is claimed. Normal Quit attempts through UI automation did not confirm termination;
the single identified disposable process was sent SIGTERM after those attempts.
Process absence and repository/output byte invariants were then verified. No other
processes or system services were targeted.
