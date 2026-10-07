# Log Messages parity

Format Patch now opens from the revision context menu with original menupatch
artwork and upstream single-revision Since or inclusive multi-revision Range
presets. One/two/continuous selection rules and actual generated patch subjects
are tested; native menu activation and field layout remain unverified. See
[FORMAT-PATCH-PARITY.md](FORMAT-PATCH-PARITY.md).

The implementation target is the actual TortoiseGit Log Messages dialog and its
selection-dependent context menus. Native macOS controls retain the three-pane
arrangement and familiar command order. The initial sidebar log table was removed.

## Revision metadata columns

The native revision table now includes the source labels Email, Commit Name,
Commit Email and Commit Date alongside Graph, SHA-1, Message, Author, Date and
Bug-ID. Core history retains `%cI` independently of `%aI`; a real repository test
uses different author/committer dates and zones across multiple commits, filtered
older matches and pinned revision scope. SHA-1 cells retain the full hash (the
visible control truncates to column width).

Normal defaults show Graph, Message, Author and Date, plus configured Bug-ID;
SHA-1 and the four extra identity columns start hidden, matching the normal Log
source definitions. A native header menu offers Reset columns followed by column
visibility checkboxes. Bug-ID is available only with the configured issue column.
Visibility saves per column; AppKit autosave handles width/order, and columns can
be resized and dragged. Reset asks the source Yes/No question in a native sheet; Yes restores default
visibility, widths and order. An attached sheet blocks another reset request.
Graph resizing now addresses the graph column by identifier rather than whichever
column happens to be first after reordering, and keeps wider user-set widths.

ID/rebase replacement and SVN-specific columns remain unported. Native header/confirmation gestures,
cross-launch width/order persistence and signed sandbox acceptance remain pending.
See [the metadata-column record](qa/log-columns-2026-10-06.json).

## Date display preferences

Settings → Dialogs now exposes the three upstream options: Short date/time format
in log messages, Relative Times in log, and Use system locale for date/time.
Their saved defaults match `SetDialogs.cpp`: short format and system locale on,
relative times off. Both Date and Commit Date use these preferences; a preference
change redraws the table without reading Git again. Relative cells provide an
absolute date/time tooltip, following `GitLogListBase.cpp`.

ISO Git timestamps now convert into the local timezone. Foundation supplies native
macOS short/long date and time layouts; disabling system locale uses
`yyyy-MM-dd HH:mm:ss`. Relative labels retain `LoglistUtils.cpp` thresholds and
resource wording, including its signed future counts. The short-format checkbox
is disabled while system locale is off. Settings save immediately through native
preferences rather than a Windows Apply button.

Focused tests cover defaults, persisted choices, timezone/DST conversion, locale
layouts and relative boundaries. A headless AppKit receiver checks actual date
cells and absolute tooltips; it displays no windows. Displayed settings gestures,
live preference refresh acceptance, translated relative labels and signed sandbox
acceptance remain pending. Relative values update when rows render; a periodic
clock refresh is not implemented. Exact Windows timezone/DST edge equivalence remains pending. See
[the date preference record](qa/log-dates-2026-10-06.json).

## Actions column

The default-visible native Actions column now uses the seven pinned original
`action*.ico` assets: five fixed Modified, Added/Copied, Deleted,
Replaced/Renamed and Conflicted slots, plus fetching/error indicators. Icons keep
their source colors and use the original slot order/spacing; tooltips and
accessibility labels identify present statuses. The column participates in header
visibility, width/order settings and Reset columns.

Core action reads use only NUL-delimited name-status data, aggregate changes
against every merge parent and handle roots, renames and type changes without
reading line statistics. The native table lazily requests visible rows through
one owned queue, deduplicates queued/in-flight hashes and caches immutable results.
Refresh/invalidation/close cancel that queue and its current Git process group;
stale completions cannot update a newer cache or show errors. Failed rows show the
source error artwork and refresh retries them. Successful history reloads retain
only results belonging to the returned list. Missing visible rows restart after a
refresh even if their hashes are unchanged.

Copy-detection/configuration variants, working-copy pseudo rows, incremental/batched
reads, displayed scroll/header/light/dark acceptance and signed sandbox behavior
remain pending. See [the Actions record](qa/log-actions-2026-10-06.json).

## Jump navigation

The top row now has the upstream ten-choice Jump dropdown in source order and
original `jumpup.ico` / `jumpdown.ico` buttons: Author Email, Committer Email,
Merge Point, Parent 1, Parent 2, Tag, Tag (FF), Branch, Branch (FF), Selection History.
Email matches are exact; branches include local and remote refs. Up searches
children for the selected first/second parent relationship, while Down searches
that parent's own revision. FF modes inspect real Git ancestry rather than only
loaded rows, so omitted intermediate commits do not break navigation.

The pinned handlers use the first selected row as their comparison origin and
start scanning beyond the last selected row; both return without changing
selection when the first selected row is the top row. A missing parent in Down
also leaves selection unchanged. An exhausted search clears selection and offers
“No more revisions found.” with the saved Do not show again checkbox. The native
implementation retains those source rules. Git failures surface as errors rather
than silently treating a failed ancestry read as a nonmatch.

Selection History retains at most 50 hashes, preserves forward history when the
highlighted fork point is reselected, and drops forward entries for a new fork.
Its arrows scroll/highlight the target without replacing selection or its details;
a target outside the current list produces an informational notice. Native history
records selected hashes in visible order; exact Windows event ordering for complex
multi-selection remains pending. Reload, selection replacement and close cancel
owned ancestry reads and reject stale completions. A normal jump selects and
scrolls its match, then uses the existing changed-file reader.

Core tests cover source boundary/multi-selection/parent/reference rules, selection
history branching and length, actual FF ancestry across filtered-out intermediates,
pre-cancel and owned stalled ancestry cancellation with reaped child and unchanged
index. A headless native receiver checks selection, highlight-only history,
exhaustion and invalidation. Displayed controls, arrow gestures, scroll/highlight
appearance in light/dark, warning suppression/relaunch, keyboard navigation and
signed sandbox acceptance remain pending. See [the jump record](qa/log-jump-2026-10-06.json).

## Revert merge parents

Single-revision Revert now uses the upstream parent submenu for merges, populated
with parent subjects and hashes. The native Yes/No confirmation defaults to No;
core applies the selected mainline without committing. Success offers OK/Commit,
and Commit routes to the existing repository's Commit workflow. Root/bare/merge/
stash conditions omit the command. Parent metadata shares owned detail
cancellation and caches immutable results. See [the user guide](REVERT-COMMIT.md)
and [Log Revert parity](LOG-REVERT-PARITY.md) for evidence and remaining multi-commit,
conflict, displayed UI and signed checks.

## Edit Notes

A single ordinary revision now offers Edit Notes with original edit artwork.
The native editor loads the active note, honors project minimum message length,
provides OK/Cancel and writes exact Unicode/whitespace/empty content. It refreshes
the selected revision's displayed notes after saving. Owned loading cancels on
selection/reload/close; saving keeps the editor guarded until completion.
Stash and its adjacent index parent are excluded following the source rules.
See [the user guide](GIT-NOTES.md) and [Edit Notes parity](EDIT-NOTES-PARITY.md) for
configuration, recovery and outstanding editor/UI/signed acceptance.

## Search fields

The search row now has a native Search in menu with independent Subject,
Messages, Paths, Authors, Emails, Revisions, Refname, Tag Info and Notes checkboxes, plus Bug IDs when issue-tracker configuration enables its column. Subject searches only the
summary; Messages searches both summary and body. Authors includes both author and
committer names; Emails includes both identities. Multiple fields match by OR.
Field selection is saved under SelectedLogFilters and reused by subsequent Log
windows. Unset/invalid preferences default to all ten implemented fields; an
explicit empty selection stays empty. Stored unsupported bits are masked out.
All selects the implemented field set; Toggle filters inverts it. Changing fields
or case mode only reloads when search text is entered, preserving a loaded list
and its pagination when no filter is active. Busy windows block these actions.
See [the selection record](qa/log-search-selection-2026-10-06.json).
Refname searches the full local/remote branch and tag reference names associated
with each commit. Annotated and nested tags resolve to their referenced commit;
annotated-tag searches also accept the upstream peeled `^{}` suffix. Lightweight
tags have no peeled search name. This field searches names; Tag Info below
provides annotation-text search. Reference mapping is captured once before filtering
and reused for row decorations. Filtering precedes the result limit, with existing
path and pinned-revision scopes retained. See
[the reference search record](qa/log-ref-search-2026-10-06.json).
Notes searches Git's displayed note text, including configured core.notesRef and
notes.displayRef selections. Returned revisions retain those notes and the native
message pane appends a Notes section. Message-only Git grep explicitly excludes
notes, so selecting Messages does not implicitly search them. Notes are fetched
separately from commit records and cached by revision during each history read;
embedded NUL data cannot break the commit-record parser. Repositories without
notes refs/configuration skip per-commit note reads. Repositories with notes still
use individual Git reads, so batched/incremental loading remains unfinished. See
[the notes record](qa/log-notes-search-2026-10-06.json).
Tag Info searches annotation text, internal tag names and tagger identity from
annotated tag objects associated with the commit. Lightweight tag names and
renamed/alias ref names remain in Refname search. Tag objects are pinned in the
reference snapshot and cached by object ID; multiple annotated tags on a commit
are included, including tags pointing to tags. The target object header and direct
commit type header are removed, matching the upstream CLI tag-info reader. Returned
rows retain tag information, and the selected message pane appends a Tag Info
section. Tagger header dates now use the Log date preferences in search, the
message pane and copied details. Stored tag information retains raw timestamps so
the message pane can reformat it when preferences change. Only header tagger lines
are converted; annotation text, malformed dates and nested tag type headers are
preserved. Clipboard reads capture one preference snapshot for all selected revisions.
A tag-date search uses the preferences captured by its history read; refresh the
search after changing date preferences to refilter existing results.
See [the tag date record](qa/log-tag-dates-2026-10-06.json). Displayed layout, links,
colors and signed acceptance remain unverified. See
[the annotated-tag record](qa/log-tag-search-2026-10-06.json).
Paths searches changed filenames for each candidate commit, including root
changes, deletions and both names of detected renames. Merge commits include the
union of changes against every parent, rather than only the first parent. Paths
are read with NUL-delimited Git name-status output, preserving literal Unicode,
newline, tab and wildcard characters. Matching uses the selected case mode and
OR combination with other fields before applying the result limit. This is
independent of the lower changed-file pane filter and existing history path scope.
Unlike upstream's cold simple-list path, which can omit rename old names, native
search includes old names consistently before/after loading commit details.
Per-commit/per-parent Git diff reads remain a performance gap; batched loading and
streaming remain unfinished. See [the Paths record](qa/log-path-search-2026-10-06.json).
The menu also offers the upstream Case-sensitive toggle, default off. It applies
to every selected field and is saved under FilterCaseSensitively for subsequent
Log windows. Plain text uses the upstream term query rules described below; a single positive
message term keeps Git's fixed-string matching with the chosen case mode. Empty search shows
unfiltered history regardless of field selection; an active positive query with no fields returns no matches; an inverted query
can match that empty selected-field text. Search/Return preserves the selected field set. Existing date, path, branch and pinned-end-revision scopes
still apply.

Non-message searches walk the scoped history before applying the result limit,
so Load more counts matching commits and older matches remain discoverable.
This currently materializes the scoped log output in memory; incremental filtering
for large histories remain unfinished. A single positive message term still uses Git's result limit; compound queries
are filtered before the matching-result limit. Returned rows now retain committer name/email
metadata as well as author identity. The native Search in layout and interaction,
match highlighting and the complete upstream default field set remain pending. This is partial upstream filter parity; see
[the verification record](qa/log-search-2026-10-06.json). Subject/case follow-up
checks are recorded [separately](qa/log-search-case-2026-10-06.json).

## Plain-text query rules

Ordinary Log search now ports the pinned `FilterHelper.cpp` substring parser and
matching algorithm: space-separated terms are required, `-term` excludes,
`+term` starts an alternative and a leading `!` inverts the result. Double quotes
keep a phrase together, doubled quotes retain one quote, and unterminated quoted
text stays a term. Only ASCII spaces separate tokens; tabs/newlines inside a term
remain literal. Terms can match across different selected fields because matching
uses their combined text, preserving the upstream field order. Subject and body
are assembled separately. Case mode applies to the whole query.

The port retains the source's less obvious rules: the ordinary word immediately
after a quoted phrase is parsed with that phrase's prefix, including literal
`-`/`+` characters; an inactive space-only query shows all rows, while a lone `!`
hides all rows. Inversion also applies to an empty selected-field text. Native
Unicode lowercasing uses Swift rather than the Windows locale implementation;
Windows-locale edge-case equivalence remains unverified. Old/current path names
remain separate searchable lines; upstream cached `path|oldPath` concatenation
and highlighting remain pending.

The search field now describes term syntax in its tooltip. Single positive
message terms retain Git grep's bounded fast path. Compound/inverted and
multi-field queries walk the scoped history and apply the result limit after
matching, so older qualifying commits remain discoverable. Match highlighting, incremental loading and native displayed search acceptance
remain unfinished. See [the query record](qa/log-query-2026-10-06.json).

## Regular-expression search

The native Search in menu now includes the source label **Use regular expression**
before Case-sensitive. It defaults off and persists under `UseRegexFilter`;
changing it reloads only when search text is entered, and busy windows block the
change. The tooltip switches to regex syntax guidance.

Regex searches use the bundled C++ ECMAScript helper over Windows UTF-16 units,
not Git's basic/POSIX regular-expression dialect. One compiled expression checks
the combined selected-field text for every candidate, with case mode and a
leading `!` inversion. Empty text fails an active expression even for `.*`.
Invalid or empty expressions leave the filter inactive, reproducing upstream
`FilterHelper::ValidateRegexp`; inversion still applies. Expressions can span
selected fields. Matching precedes the result limit and retains date/path/branch
and pinned-revision scope.

Length-framed records preserve embedded NUL, newlines and surrogate pairs. Regex
work uses one batched helper invocation per history read; refresh/close cancel its
owned process group and children. A five-second helper deadline uses its own token
and does not cancel the owning Log request. Temporary input/output files are
cleaned up. The runtime retains its universal macOS 13 slices, inherited sandbox
signing route and redistributable source/provenance checks.

Batched filtering currently buffers scoped history and selected-field text; the
existing 16 MiB helper input limit can report an error for very large requests.
Incremental batches, Windows locale/case-folding edge cases, match highlighting,
actual native toggle/persistence gestures and signed sandbox acceptance remain
unverified. See [the regex record](qa/log-regex-2026-10-06.json).

## Bug IDs column and search

Log now reads one issue-tracker configuration snapshot per native history reload
and passes it into history, so the column gate and extracted row IDs use the same
properties. The Bug IDs column and Search in item appear when `bugtraq.url` or
`bugtraq.logregex` is nonempty, matching `UpdateProjectProperties`. The field bit
participates in saved selection, All and Toggle filters. Returned rows retain their
extracted IDs, and the native table refresh signature includes them so changed
configuration updates displayed values even if commit hashes are unchanged.

IDs come from the existing ProjectProperties port: `.tgitconfig`/include and
Git scope precedence, one/two ECMAScript extraction expressions or a message
`%BUGID%` template, duplicate removal, numeric ordering and space-separated
output. Bug IDs queries search those extracted IDs rather than arbitrary message
numbers. They combine with other fields and work with plain terms, regex/case
mode and matching limits. Bare repositories read the committed project config.
The Log-specific extraction helper mode ignores invalid regex syntax, as the
upstream `FindBugIDPositions` does; existing strict Commit/config validation
behavior is preserved. Missing helpers, timeouts and cancellation still propagate.
Property Git reads and regex extraction receive the owned history token.

Configured regex extraction currently starts one helper per candidate/returned
commit (cached within that history read); batched extraction remains pending.
Windows `StrCmpLogicalW` locale/punctuation and case-equivalent duplicate behavior
are not fully reproduced by Swift natural sorting. Native displayed column/menu
visibility, preference/config refresh, links/highlighting and signed sandbox
acceptance remain unverified. See [the Bug IDs record](qa/log-bugs-2026-10-06.json).

## History-load cancellation

Every native Log history read owns an OperationCancellation token. Refresh/search
cancels the previous read before creating another; closing or invalidating Log
cancels its active read and advances the generation so stale results cannot replace
current rows. Log may close during history loading, while mutations, viewer work
and attached sheets retain their existing close guards. Mutation work cannot be
replaced by a history reload. Cancellation does not show an error for the stopped
request.

The core history API now accepts optional cancellation without changing existing
callers. It checks before any work (including zero-limit/unborn reads), during ref
and commit parsing and between merge parents, and passes the token through every
Git command, including notes, tag objects, path diffs and final HEAD/ref metadata.
The shared process runner terminates only the owned child process group. A cancelled
read never returns its rows. Other Log operations still need their own cancellation coverage; large-output
buffering and incremental loading remain unfinished. See [the cancellation record](qa/log-history-cancel-2026-10-06.json).

## Changed-file detail cancellation

Each native changed-file detail selection owns a separate cancellation token.
Selecting another revision (including clearing selection), refreshing history or
closing/invalidating Log cancels the previous detail read and advances its
generation. Stale results cannot replace current files or clear a newer token;
cancelled reads do not display an error. Existing first-parent detail semantics
are preserved.

The core `files(in:cancellation:)` API checks before work, between name-status,
numstat and raw Git commands and after parsing, passing the token to each command.
A real repository regression stalls numstat after name-status, cancels its owned
wrapper and child, verifies independent detail reads and exact unchanged index
bytes, and then reads the correct file/statistics again. Native gesture and signed
close/quit acceptance remain unverified. See [the detail cancellation record](qa/log-detail-cancel-2026-10-06.json).

## Full-detail clipboard cancellation

Full-detail copy now owns its own cancellation token. Another copy (including a
simple copy), revision selection, history refresh or window invalidation/close
cancels that read. Generation checks prevent stopped work from changing the
pasteboard, clearing a newer request's indicator or showing a cancellation error.
A cancelled read preserves existing pasteboard contents; a successful read writes
all selected revision details together.

`commitLogText(revision:includePaths:cancellation:)` passes the token through
revision pinning, message/notes/ref/tag reads and changed-file reads for each
merge parent, checking cancellation during tag/path assembly and before return.
A real repository regression stalls the annotated-tag read with paths disabled;
it verifies process/child cleanup, pre-cancel rejection, independent read success,
unchanged index bytes and identical subsequent clipboard text including notes and
tags. Existing changed-file cancellation tests cover the shared path reader.
Native pasteboard and displayed selection/refresh/close gestures remain unverified.
See [the clipboard cancellation record](qa/log-clipboard-cancel-2026-10-06.json).

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
| Columns | ID/rebase and SVN columns; displayed header/reset and cross-launch persistence acceptance |
| Graph | Collapse/expand, hidden refs and all merge parent choices; the working-tree row is now implemented with basic comparison/Bisect routing, see [Bisect parity](BISECT-PARITY.md) for remaining row gaps |
| References | Branch/ref chooser, remote ref deletion and tracking menus |
| Search/filter | Full history scope controls, search highlighting, displayed jump/selection-history acceptance and keyboard navigation; implemented fields/modes are recorded above |
| Files | Multi-revision union, multi-file diff, file log/blame, restore, save/export revision, open/editor/Finder actions |
| Revision menus | Clicked-ref targeting, squash, ref containment/search; revision Export and revision/working-tree Bisect now have native routes, see [Export](REVISION-EXPORT.md) and [Bisect](BISECT-PARITY.md); see later sections for browser/patch commands |
| Mutations | Full branch/tag options, checkout branches, advanced Cherry Pick options and displayed acceptance ([audit](CHERRY-PICK-PARITY.md)), multi-commit Revert and other operations, conflict continue/abort |
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
The output uses LF and the Log date preferences for author/tagger dates; tag
object/type-commit headers are omitted. Full upstream tag presentation and localized
relative labels remain pending, as described in
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


## Historical file Open and editor actions

Pinned `GitStatusListCtrl.cpp` lines 1884–1889 expose View revision in alternative
editor, Open and Open With for a single non-directory, nondeleted/nonmissing file.
`OpenFile` (4673–4699) reads historical contents into a temporary file, marks it
read-only, then launches the configured editor, default association or Open With.
Log now exposes these three commands with the original notepad/open icons under
its single-file historical gate. Deleted rows and gitlinks omit them.

The model captures exact bytes at the selected pinned revision with the existing
repository security-scope check. Open With presents a native application-bundle
chooser; cancellation does not create a preview. The default action uses the macOS
file association, and alternative editing uses the same saved TextEdit/custom-app
preferences as Commit. Explicit chosen apps retain their selected resource scope
until the workspace callback completes.

`HistoricalFilePreview` creates a unique private directory (0700) and read-only
regular copy (0444), preserving the filename extension and including the short
revision hash. Historical symlink blobs remain literal target text; targets are
never followed. Working-tree, empty-tree, unpinned, non-blob and malformed preview
inputs are rejected. Copies stay alive for the application session, including
after Log closes. Failed launches discard their copies, and normal application
termination discards all retained previews. External edits cannot change the
repository through these copies.

Two new regressions check exact text/binary/symlink contents, literal Unicode and
newline filenames, distinct private copies, read-only modes, disposal, invalid
inputs and raw index/HEAD/working preservation. The comparison suites passed 20
tests; alternative-editor preferences passed two more. Debug and unsigned App Store
builds and both bundle/runtime audits pass. The expanded SwiftUI menu is factored
into a separate view-builder expression to avoid the Xcode type-checking limit.

Native QA verified all three commands in the first historical-file context menu
and invoked the alternative-editor action. A temporary `source-e9cae95.txt` copy
was created for the selected revision and retained during the session. TextEdit
presented an Open chooser, so an actual historical document in the editor was
not verified. UI automation then returned a ScreenCaptureKit invalid-parameter
error; that observation is not evidence of a TurtleGit launch failure or success.
The same QA process subsequently quit normally, the preview directory disappeared,
and exact HEAD, raw index and original working bytes remained unchanged. No
TurtleGit test processes remained. No new screenshot is claimed for this run.

Native default-association document acceptance, Open With selection/cancel,
custom-editor errors, binary/symlink/rename and deleted/gitlink menu variants,
read-only document behavior, repeated-session cleanup and signed sandbox handoff
remain pending. This is a partial port of historical opening, not full native
editor or file-context-menu parity.

## Historical multi-file folder Export (2026-10-05)

Upstream `GitStatusListCtrl.cpp::FilesExport` (4504–4544) was compared directly.
Log now includes Export with the original colored icon for eligible selections.
A native directory chooser captures the selected revision and files before the
operation. Exports preserve repository-relative directories and visible list
order, replace existing destination copies, skip deleted files and gitlinks,
and read exact blobs from a pinned commit. Historical symlink blobs become
regular files containing the target text. Each failed file offers a native
Ignore/Abort sheet; Ignore continues and Abort stops subsequent files while
retaining successful copies. Cancelling the directory chooser starts no export.

Core preflight rejects Git metadata, escaping destination parents and selected
working-source aliases before writing. Per-file checks repeat parent/source
validation, use a sibling temporary file and atomically replace the destination.
A chosen folder's security scope stays active throughout the operation, and the
App Store route requires the repository grant too. These unsigned checks do not
prove signed sandbox acceptance.

Six export regressions pass, including two new historical tests covering a
moving HEAD, literal Unicode/newline paths, binary blobs, broken symlink target
text, nested hierarchy, overwrite, deleted/gitlink skipping, continuation after a
missing blob, destination-parent aliases and raw index/HEAD/working preservation.
Debug and unsigned App Store builds and both bundle audits pass (64 icons,
11 universal Git Mach-O files).

Native QA displayed Export for three selected files. Menu accessibility IDs
became invalid between tool calls and the menu did not remain visible for a
successful invocation. The chooser and Ignore/Abort end-to-end acceptance are
therefore pending; no exported native output or new screenshot is claimed.
The incidental read-only comparison was closed, the one QA app quit normally,
and exact fixture HEAD/index/working bytes were unchanged with no QA process
remaining. Native overwrite/cancel/error continuation, signed sandbox grants,
and exact upstream marked-row menu eligibility/order remain pending. Full Log
and file-context parity remains incomplete.

### Native Export acceptance follow-up at 35d4672

A new single-instance QA session successfully invoked Export, chose a separate
folder, and wrote all three selected files. Filesystem verification matched the
selected commit's 30-byte UTF-8 BOM/CRLF/no-final-newline text, four-byte binary
blob under `nested/`, and 14-byte broken symlink target as a regular file. The
staged and working versions of the text file differed from the selected blob;
neither was changed. Exact HEAD, raw index and working bytes were preserved.

With the first destination (`link`) deliberately occupied by a directory, the
native warning showed the file, full revision, destination and `Is a directory`
error. Ignore retained that directory and exported both later files exactly.
Abort retained the directory and wrote neither later file. No sibling temporary
files remained. A subsequent chooser Cancel returned to Log without starting an
export. The app quit normally and process absence was checked before any further
UI observation. No code change was needed for these acceptance checks; the prior
menu automation failure did not reproduce after explicitly raising Log.

[Recorded hashes and native coverage](qa/historical-export-2026-10-05.json) are
included with an [actual Log capture](site/assets/log-historical-export.png).
The screenshot captures the underlying Log selection during export; it does not
capture the separate AppKit warning sheet. Native overwrite, deleted/gitlink
marked-row menu gates and ordering, dark-mode warning appearance and signed
sandbox access remain pending. Full Log parity remains incomplete.

### CI compiler follow-up

GitHub's Swift 6.1.2/Xcode 16.4 rejected the Export `Task` at 35d4672
with a type-checking timeout, before integration tests could run. Local builds
had passed. The task now calls a separate async function with explicit result
and message types; the failure message is assembled from a typed string array.
This retains the verified export behavior while reducing inference complexity.
The correction must pass a fresh GitHub run before CI compatibility is claimed.

## Compare two historical files (2026-10-05)

Upstream `GitStatusListCtrl.cpp` menu eligibility (1796–1811) and command
implementation (2260–2285) were compared directly. Log now offers Compare two
files for exactly two visible selected non-gitlink files. It preserves displayed
row order, compares distinct paths in the selected revision, and independently
uses that revision's first parent for each deleted side. Both revisions are
resolved to commit hashes before a snapshot reaches the existing read-only
comparison viewer. Identical paths, wrong selection counts, missing blobs and
non-file/gitlink content are rejected. RepositoryModel applies the existing
App Store repository-grant check before reading historical contents.

A real Git regression verifies a deleted left side, reversed order/deleted right
side, literal Unicode/newline/leading-magic filenames, symlink target blobs,
exact raw index preservation and unchanged pinned bytes after HEAD advances.
All seven FileComparison tests pass. Native QA selected a deleted/modified pair
but context-menu automation returned `noWindowsAvailable` and invalidated-row
errors before invocation. The process was still alive and its Log contents were
observable; those errors do not establish a TurtleGit failure. Native menu/viewer
acceptance is pending, with no new screenshot claimed. The one QA app quit
normally; exact HEAD, raw index, later working bytes and the deleted path's
absence were preserved, and no QA process remained.

The file menu is now ordered Show log/old-name/Blame, Export, Save revision,
alternative editor, Open and Open With for the implemented commands, matching
the relative upstream order. A separate view-builder reduces Swift inference
complexity after the earlier Swift 6.1 Export timeout. Exact marked-row gates,
missing restore/prepare-diff/explore commands, alternative diff tools and signed
sandbox validation still prevent full file-menu parity. Native binary/symlink,
root/both-deleted/merge pair variants and reversed order remain pending.

The previous compiler correction at 6b3d697 passed the full GitHub macOS workflow,
including integration tests, Debug/Finder build, universal Git runtime and
unsigned App Store build/audit. This does not prove the new pair change or signed
distribution readiness.

## Unified diff for a file selection (2026-10-05)

Upstream `IDGITLC_GNUDIFF1` (2290–2365) iterates selected rows and appends each
file's patch to one read-only viewer. The Log file menu now accepts multiple
selected files for Show changes as unified diff. It captures visible list order,
reads only those paths against the selected commit's first parent (or root), and
concatenates their patches. Rename entries include old and new literal paths so
Git emits the rename rather than just the destination addition. Duplicate paths
are ignored; empty selections are rejected. The operation is busy-guarded and
checks the App Store repository grant before reading. Unified patch text remains
in the existing separate read-only sheet.

A new real Git regression verifies root additions, multi-file ordering,
rename-from/to metadata, leading pathspec-magic/Unicode/newline names, exclusion
of an unselected change and later staged/working contents, duplicate filtering,
and exact raw index/HEAD/working preservation. The five CommitHistory tests pass.
The original assertion expected the old Unicode path unquoted in the patch;
it was corrected to account for Git's quoted patch headers without changing the
fixture's names or content coverage. Debug builds pass. Native multi-file patch
sheet acceptance, configured filters/tools, per-parent merge rows and error-partial
output still require verification.

The separate historical pair native retry again selected both rows but returned
an automation `noWindowsAvailable` error when opening the context menu. Its one
QA app quit normally; exact repository state and process absence were checked.
No native pair handoff or new screenshot is claimed. This does not block the
remaining source port, and full Log parity remains incomplete.

## Reveal in Finder (2026-10-05)

Upstream `GitStatusListCtrl.cpp` Explore eligibility (1898–1899), dispatch
(2151–2153), and `CommonAppUtils.cpp::ExploreTo` (467–489) were audited. Log now
includes Reveal in Finder after Open With, with the original Explorer icon.
A single non-deleted historical row and a working-tree repository are required;
gitlink directories remain eligible. The command selects the current disk item.
If it no longer exists, it opens the nearest existing parent directory inside
the repository. It does not check out the historical blob. The App Store route
checks the retained repository grant before resolving the path.

The core resolver handles literal paths and broken symlink items, rejects bare
repositories, Git metadata and escaping parent aliases, and performs no Git or
filesystem mutation. Six WorkingFileRestore tests pass, including two new reveal
regressions for normal/broken-link selection, missing nested/root fallback,
unsafe paths and exact raw index/HEAD preservation. Debug and unsigned App Store
builds and both icon/runtime audits pass (64 icons, 11 universal Mach-O files).

Native QA invoked Reveal on a modified file in Log. Finder selected `right.txt`
and displayed its later working contents, which differ from both selected and
staged bytes. The first menu showed Show log/Blame, Export, Save, editor, Open,
Open With and Reveal in that relative order. Selecting the older root commit's
`left.txt`, absent from the current disk, opened the current repository folder
without restoring the file. A transient activation interruption was refreshed
and the missing-file handoff retried before acceptance was recorded. Only the
QA repository Finder window was closed; TurtleGit quit normally. Exact HEAD,
raw index, working bytes and deleted-file absence were preserved, with no QA
process remaining. [Native evidence](qa/log-reveal-2026-10-05.json) records this
coverage. No new screenshot is claimed.

Native nested missing-parent, symlink, gitlink/bare/deleted menu variants and
signed sandbox handoff remain pending. Full Log menus, marked-row semantics and
historical comparison acceptance are still incomplete.


## Mark for comparison (2026-10-05)

Audited upstream `GitStatusListCtrl.cpp` menu construction (1894–1913),
PREPAREDIFF dispatch (2155–2166), and external DiffLater import (3170–3179),
against pinned upstream `7338078f8ddd924b8cddee35f512f2286072136d`.
Log now offers Mark for comparison and a dynamic Compare with action for one
non-deleted historical regular file. Both use original comparison artwork.
The mark belongs to that Log dialog, survives revision changes and comparison,
and disappears when the dialog closes. Same-path labels show the saved full
revision; different-path labels show the saved path and eight-character hash.
Both endpoints are resolved to commits before content is read. The App Store
route checks the retained repository grant.

Eight FileComparison tests pass, including a new real-Git regression for
same/different literal paths, binary contents, Unicode/newlines, invalid paths,
pinning across a later commit, and exact index/working/HEAD preservation.
Debug and unsigned App Store builds and resource/runtime audits pass (64 icons,
11 universal Mach-O files). The preceding base commit's GitHub macOS and Pages
runs also passed; this change's CI must be checked separately after push.

Native QA marked `right.txt` in the latest commit, changed to the older revision,
and invoked Compare with using the full-hash label. The viewer showed the marked
15-byte `selected right` and older 13-byte `parent right`, with editing and Save
disabled. The mark remained available for the older revision's `left.txt`; its
menu label was `Compare with right.txt:3afaeae`, and the viewer compared the same
marked content with 12-byte `parent left`. HEAD, raw index and working bytes
remained exact; the deleted disk file was not restored. The one QA app quit
normally, with no remaining QA process.
[Recorded acceptance evidence](qa/log-mark-2026-10-05.json) and the
[actual native screenshot](site/assets/log-mark-comparison.png) document the
checks. The screenshot shows the same-path viewer with an inactive title bar;
it does not capture the context menu.

External working-file DiffLater import, gitlink comparison, alternative diff
tools/Shift behavior, long-path compaction,
additional native file types and signed sandbox acceptance remain pending.
This section does not establish full Log parity.


A follow-up source audit of `Git.cpp::GetShortHASHLength` (3011–3014) found a
fixed return value of eight, not a configurable hash length. Different-path
comparison labels now use eight characters, matching this pinned upstream.
The native record above intentionally retains the seven-character label seen
before this correction; it proves the viewer route, not the corrected label.
Long-path compaction remains pending. Explorer's `ContextMenu.cpp` DiffLater
handler (1350–1371) stores an absolute working-file path, consumes it after
comparison, and supports Control to clear and Shift for an alternative tool;
that shared Finder/app route still needs porting.


The external mark's private bookmark store and metadata-only Finder snapshot
now have persistence, renewal and conditional-consumption regressions. The
Finder/app working-file routes and Log external-mark comparison now open the
native viewer. See
[comparison mark parity](COMPARISON-MARK-PARITY.md) for the complete source audit
and required integration. This storage foundation does not change the verified
historical Log comparison route.


Log external working-file mark import, mixed historical comparison, shared-token
consumption and dialog-local reuse are now implemented and natively verified
for a regular file outside the repository. Only that working pane becomes
editable. The selected historical revision remains pinned. See
[comparison mark parity](COMPARISON-MARK-PARITY.md) for tests, the native screenshot
and remaining signed/tool/path variants. This does not establish full Log parity.


Native mixed-comparison Save now has exact UTF-16/BOM/CRLF and 0755 acceptance,
including external-change refusal and Reload Cancel/discard behavior. A native
prompt bug was fixed so Reload/Close/Quit name the actual edited file, and all
three corrected labels were checked. See [comparison mark parity](COMPARISON-MARK-PARITY.md)
for the QA record and remaining active-pane/signed sandbox limitations.


Log revision and selected-file unified-diff actions now use the shared external
viewer preference and Shift inversion. Exact non-UTF-8 patch bytes are preserved
through the external preview, with a real Git apply-check regression. The
built-in sheet remains available through the same choice. Native launches and
Shift interaction remain unverified; merge-parent/combined variants and full Log
parity are still pending. See [unified diff viewer parity](UNIFIED-DIFF-VIEWER-PARITY.md).

Native revision menus now include Merge and Rebase onto selection, with original
icons, reference/hash presets and fresh repository-state guards.
[Merge/Rebase handoffs](LOG-MERGE-REBASE.md) records origin recovery and limits.

Single-revision Log Export now has the original icon and a native archive
dialog with HEAD/Branch/Tag/Commit, Whole Project and overwrite confirmation.
[Revision Export](REVISION-EXPORT.md) records the implementation and remaining
displayed, signed sandbox and entry-point checks.

## Compare parent with working tree

The historical file menu now offers Compare parent with working tree, using the
original comparison icon and a parent subject/hash label. Parent subjects are
loaded for ordinary commits as well as merges. The command uses the first parent
for ordinary rows and each selected occurrence’s own parent for merge groups; it reuses the
root revision-file comparison viewer, including rename mapping and missing sides.
Root commits and the synthetic working-tree row have no command. Busy, bare,
invalidated, multi-revision and empty file selections refuse the handoff.

This follows GitStatusListCtrl.cpp's GetParentCommitInfo and StartDiffWC(parent),
with per-parent groups now loaded into the native file list.
Shift selection of an external two-pane diff tool is also pending. The native
receiver checks model dispatch and actual comparison bytes with an injected root
viewer callback; displayed menu/window and signed sandbox acceptance are separate.

## Per-parent file data

GitRevLoglist.cpp reads each actual parent in commit order and retains separate
file occurrences. The Core `logFileGroups` reader now follows that contract:
actual metadata from the pinned commit, one group per parent (including empty
groups), and one empty-tree group for a root commit. Each group retains its
parent hash and a scoped Log entry for the existing patch readers. Paths,
renames, statistics and submodule modes remain separate across parents.

Native Log now loads all merge parent groups and displays Diff with parent
headers in the same file table. Empty groups remain visible unless a path filter
excludes them. Headers are removed from selectable file IDs; duplicate paths have
separate occurrence IDs that never replace their actual filesystem path.
Comparison and parent-to-working requests batch by parent, so a busy root model
cannot discard a later group. Selected unified diff retains one patch for each
parent occurrence, while deduplicating repeated selections of that occurrence.
Deleted-file pairs resolve each side’s own parent. File log/open/export/clipboard
continue to use actual paths and the selected commit, not the occurrence ID.

Headers currently occupy the Path column as native table rows; full-width group
styling, collapse controls and displayed light/dark/keyboard/VoiceOver acceptance
remain pending. The pinned reader emits per-parent rows; MERGE_MASK has handlers and a reserved
group header but no row producer in the current source. A combined-merge viewer
requires further source/runtime evidence. External two-pane tool selection remains
separate parity work. Root viewer batch
wiring is compiled and inspected; the native fixture injects its callback and
reads actual Core comparisons. Successful displayed viewer dispatch and signed
sandbox access remain unverified.

## Working-file Add and Commit

The working-tree file menu now offers Add for selections containing an unversioned
file, plus Commit for the selected paths, using the original icons. Both read fresh
working status and retain selection/invalidation guards before handing off. Add
reuses the native Add progress route; Commit reuses the existing scoped Commit
dialog and now refreshes repository Logs on completion. These commands pass paths,
not the whole repository. Shift Add as executable/symlink, the remaining file
commands and displayed menu/dialog acceptance are still pending.
