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
message term uses the source display matcher in native Log; the match-only Core
API retains its Git fixed-string fast path. Empty search shows
unfiltered history regardless of field selection; an active positive query with no fields returns no matches; an inverted query
can match that empty selected-field text. Search/Return preserves the selected field set. Existing date, path, branch and pinned-end-revision scopes
still apply.

Native Log now limits the raw scoped walk, then keeps search-hidden rows for
graph/rollup state before display filtering. Its configured count applies to
raw records; No limitation removes the count cap. The match-only Core API still
provides its prior matching-result limit contract. Both reads currently materialize
their output; incremental filtering remains unfinished. The source count/date
controls are covered by the history-limit checkpoint below. Returned rows retain committer name/email
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
message terms use the source matcher in native Log, with the same raw batch as
compound/inverted and multi-field queries. The match-only Core API retains the
older Git-grep/matching-result limit contract. Increasing a configured count or
choosing No limitation can reveal older qualifying commits. Match highlighting, incremental loading and native displayed search acceptance
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
not the whole repository. Displayed Shift Add mode menus, the remaining file
commands and displayed menu/dialog acceptance are still pending.

## Working-file Revert and index flags

Log now offers scoped Revert through the existing Revert chooser/progress route.
Mixed selections pass only versioned files. The working-tree row also reads index
flag metadata without refreshing/writing the index. Locally ignored rows remain
visible, including typed gitlinks, so users can clear assume-unchanged and
skip-worktree flags. Status shows the current flag and Commit is disabled for the
marked locally ignored file. Flag menus use the existing marked-row policy and
confirmation; the Core engine revalidates current flags under its private index
lock. Confirmation cancellation, changed revision selection and invalidation
prevent dispatch. Successful or partially successful changes request Log refresh.

The hidden native check executes real assume/skip/clear and Revert progress in a
disposable repository, checks restored bytes and unrelated file/HEAD preservation,
and removes owned Trash results. Confirmations and root callbacks are injected.
Revert currently opens the existing chooser instead of upstream’s direct status-list
confirmation/progress sequence. Displayed dialogs, partial flag failures through
this new route, locally ignored Revert semantics and signed sandbox access need
further acceptance work.

## Historical file Revert

Historical file menus now offer Revert to this revision and Revert to parent
revision with the original Revert icon. Parent groups retain their actual parent
hash, including parent 2 and duplicate-path occurrences. Like upstream's
GitStatusListCtrl.cpp RevertSelectedItemToVersion, restoration uses the old path
for renames, checks out into both index and worktree without moving HEAD, and
parent-added paths use rm --cached --ignore-unmatch while retaining working data.
Existing regular files and symlinks go to Trash by default; gitlink directories
are not recycled. Per-file failures offer Ignore/Abort and completion reports
counts by revision. Changes refresh repository Logs.

Targets are pinned and checked against actual commit/parent files, with literal
pathspecs and confined destination paths. A missing historical old-name target is
rejected before recycling local data. This deliberately avoids upstream's possible
checkout failure after recycling a rename's old path. Checkout failures after a
successful recycle retain the resulting Trash URL. The supported older Git versions
receive the validated hexadecimal hash directly, without checkout's newer
--end-of-options option.

Core fixtures cover raw bytes, literal unusual paths, parent-added preservation,
current/parent restore, renames, invalid selections, unchanged HEAD and unrelated
staged content. Hidden native fixtures execute current and parent-2 restoration,
duplicate-parent occurrences, summaries and stale/bare/invalidation guards with
injected dialog callbacks. Displayed menus/dialogs, the Ignore/Abort failure
interaction and signed sandbox acceptance remain unverified. Full port parity is
still incomplete.

## File Ignore menu

Log now offers Add to ignore list when the marked file is unversioned or deleted,
including historical deletions. Name, extension and single-file containing-folder
choices reuse the native Ignore dialog. Mixed extensions use separate name/mask
commands as in GitStatusListCtrl.cpp; matching extensions retain the submenu.
Original Ignore icons remain attached. Selections are read in visible list order;
actual historical parent groups or fresh working status are checked before the
handoff. Busy/bare, changed selection, invalidation and externally staged cached
unversioned rows prevent dispatch. Ignore writes rules without removing tracked
files or their working contents. Rule changes now refresh all repository Logs.

Hidden native fixtures verify path/mask/folder routing and historical deleted
paths, then execute the native Ignore model to write a literal unusual filename
rule and refresh unversioned visibility. Dialog and root/completion callbacks are
injected. Menu layout and displayed Ignore interaction, signed sandbox access,
working-file Delete and other outstanding file commands still need acceptance.
SwiftUI file selection now retains the last singly added selection as its mark.
Ambiguous range selection retains the existing mark or falls back to the first
selected visible row; physical mouse/keyboard acceptance remains pending.

## Working-file Delete

The working-tree file menu now offers Delete for an unversioned, ignored-copy or
missing marked file, using the original Delete icon. The table's
native Delete command uses the narrower unversioned/ignored-copy keyboard policy.
Shift requests permanent deletion; otherwise selected existing files go to Trash.
A native Yes/No confirmation precedes mutation. Like upstream DeleteSelectedFiles,
the operation processes all selected paths and removes their exact index entries,
including tracked paths in a mixed selection, without moving HEAD.

The existing Core delete engine locks the index and revalidates selected status;
it never falls back from failed Trash to permanent removal. Log retains resulting
Trash URLs, refreshes repository Logs on success/partial file mutation, and refuses
changed revision/file selection or invalidation while confirmation is held. Native
fixtures inject confirmations and completion callbacks while executing real Trash,
permanent deletion and index changes in disposable repositories. Displayed menus,
keyboard events, confirmation interaction, partial errors through this new route,
selection-mark fidelity and signed sandbox acceptance remain pending. Historical
file rows do not offer Delete.

The file-selection binding now remembers the last singly added row, clears the
mark when its selection disappears or the revision changes, and excludes group
headers. Delete, Ignore, working index flags/Commit eligibility and historical
Revert/parent menu titles share that mark. File execution order remains visible
list order. Hidden fixtures use the real binding to select a tracked row then add
an unversioned row, and parent 1 then parent 2 duplicate-path occurrences.
Ambiguous multi-row additions retain an existing selected mark or use a first-row
fallback. Right-clicking an already selected row, range endpoints, keyboard
anchors and displayed selection behavior still require runtime acceptance.

## Show submodule log

Gitlink rows now offer Show submodule log with the original Log icon, separately
from Show log in the parent repository. The child repository is validated through
the existing submodule-comparison reader. Historical nondeleted rows default to
the exact recorded gitlink hash, matching LogSubmoduleShowRevision (default true).
Disabling that preference, selecting a working-tree row, or selecting a deleted
historical gitlink opens general child history. Deleted rows resolve the actual
parent group's gitlink; merge file occurrence metadata is retained.

The route checks fresh working status or actual historical group membership,
repository access and child checkout identity before handing off. An uninitialized
checkout or unavailable pinned child revision reports an error without fetching
or initialization. Busy/bare, multiple-file, changed revision/file selection and
invalidation guards prevent stale dispatch. Root wiring opens child Log with no
parent path filter, retaining the parent's access lease and selected Git runtime.

Hidden native fixtures exercise literal gitlink paths, parent versus child Log,
recorded hash and actual child history range, preference-disabled/working/deleted
history, unavailable revisions, missing initialization and exact index preservation.
Root callbacks are injected. Displayed menus/child windows, event input and signed
sandbox acceptance remain pending.

## Working-file Shift Add modes

With Shift held, an eligible marked unversioned file now offers Add as Executable
(+x) and Add as Symlink with the original Add icons. All selected paths are passed
to direct Add progress, as in GitStatusListCtrl.cpp; ordinary Log Add now also uses
that direct route, including selected folders. The Explorer/main Add chooser route
is retained separately. The progress model carries the initial mode through the
reviewed-path validation into the existing private-index Add engine. Executable
and symlink modes update Git index entries to 100755 and 120000 without chmod or
creating a disk link. Selected directories keep their child modes unchanged.

Marked-row eligibility, fresh unversioned status, real file type for Shift modes,
access and stale revision/file-selection guards precede handoff. Progress completion
refreshes repository Logs. Alternate mode post-actions are shown only after normal
Add; Commit remains available after a successful variant Add. Native fixtures run
real mixed file-mode Add progress, raw blob checks, unchanged regular working-file
permissions/types, directory/gitlink Add, held-index/pre-cancel refusal and unrelated
staged/HEAD preservation. Root callbacks are injected. Displayed Shift events,
progress post-action menus and signed sandbox acceptance remain pending.


## File clipboard headings and displayed values

A follow-up audit of the pinned `GitStatusListCtrl.cpp` menu, `GetCellText` and
`CopySelectedEntriesToClipboard` corrected Log's file clipboard formatting.
The upstream `COPYEXT` command means **Copy all information to clipboard**;
it is not a separate extension-only command. The four existing named commands
remain, with the original Copy artwork.

Full paths, relative paths and file/folder names now end each selected row with
LF, including the last row. All information adds the Path, Extension, Status,
Lines added and Lines removed headings followed by tab-separated cells. Log
uses a shared status-list formatter while retaining each merge-parent occurrence
and its own statistics. Working-tree copies use the displayed Assume unchanged
or Skip-worktree status instead of a generic Modified label. Group headers and
filtered-out files are excluded; busy and invalidated models preserve the
previous clipboard.

The native Path cells now show the default source `(from old path)` rename/copy
suffix, and Extension includes the leading dot, including dotfiles. Typed gitlinks
have no extension. These are display labels; Git commands and the three path/name
copy commands retain actual paths. The formatter preserves Unicode and embedded
newlines/tabs rather than quoting or deduplicating paths.

The five focused Core tests cover both existing status-list consumers and the
new occurrence-aware format, different statistics for duplicate paths, displayed
flag overrides, rename/copy labels, reordered/empty column inputs, literal names
and gitlinks. Native receiver checks use actual historical rename/merge rows and
working index flags with a private pasteboard; resulting records are in
[the file clipboard QA record](qa/log-file-clipboard-2026-10-07.json).
The Core tests do not establish displayed interaction acceptance.

Log's current-column context command, native column visibility/order persistence,
AbbreviateRenamings setting consumer, composed light/dark appearance, physical
menu/keyboard gestures and signed sandbox acceptance remain pending. The default
five-column clipboard change does not establish complete menu or Log parity.


## Walk Behavior

The native Log now exposes the six pinned Walk Behavior menu choices, in source
order: First Parent, No merges, Follow renames, Full history, then Compressed
Graph and Show labeled commits only. Each choice has a checked state; the button
shows when any choice is active. The two graph modes replace one another and
turn off when selected again. Busy and invalidated models refuse changes.

The first four options use Git's `--first-parent`, `--no-merges`, `--follow` and
`--full-history`. Follow renames requires a single file scope, turns off All
Branches, restores the original file scope instead of Whole Project, and disables
both controls while active. Changing scopes clears Follow. Eligibility checks
working directories and committed tree modes, including bare repositories where
Git's own administration directories must not be mistaken for committed folders.
Typed gitlinks are also excluded even without a checkout. Literal Unicode,
newline and wildcard-like filenames retain their meaning.

Compressed Graph keeps HEAD and supported reference labels, merge commits and
fork points. Labeled-only keeps HEAD/reference rows. The synthetic working-tree
row remains visible. Graph copies bridge hidden **loaded** linear ancestors;
actions, parent comparisons and file groups continue to use actual commit parent
hashes. Merge/fork node shapes retain actual topology even when graph edges
collapse. Ordinary walks now use the same `--parents` flag as upstream
`GetLogCmd`. Git's rewritten links are stored separately as graph parents; actual
parents are recovered in bounded batches from pinned commit hashes. This connects
path-filtered rows across omitted intermediate commits while file groups, path
search and parent actions still use the real commit topology. Full history keeps
raw parents, matching upstream's mutually exclusive flag choice. The native Log
applies display projection separately.

Four Core tests exercise real merge and rename histories, combined First Parent
and No merges, a merge that hides mainline path changes unless Full history is
used, scope restrictions, a bare administration-directory name collision, readonly
repository preservation and graph projection invariants. The existing 34 Commit
History tests also pass. The native receiver exercises all six model handlers,
working-row/graph alignment, literal rename following, mutually exclusive modes,
All Branches/Whole Project transitions, scope reset and busy/closed guards, with
an actual hidden hosted Log view. See [the walk QA record](qa/log-history-walk-2026-10-07.json).

Compressed search now retains raw rows and forced state propagation; see the
search-hidden walk section below. Follow renames hides the native graph, as
upstream does. The synthetic working row above a hidden HEAD and displayed
light/dark/keyboard/VoiceOver acceptance and signed
sandbox behavior remain pending. Compression currently applies to the loaded
revision batch, so Show next 200 can reveal more retained nodes. This is progress
toward the complete upstream walk/graph behavior, not full Log acceptance.

The graph-parent regression additionally verifies a real omitted path ancestor,
connected normal/labeled graph rows, actual file lists and parent-revert targets,
Full history raw-parent behavior and exact repository preservation. The native
receiver checks the same path graph through `LogWindowModel`. See
[the graph-parent QA record](qa/log-graph-parents-2026-10-07.json).

## View → Labels

The four upstream label switches now appear under View → Labels in source order:
Tags, Local branches, Remote branches and Other refs. All start enabled, with
settings saved separately for each repository. Normal history redraws its label
cells without reloading or changing selection. Compressed/labeled-only history
refreshes the projection when a switch changes. Busy and invalidated models
refuse changes.

The visibility mask follows `LOGLIST_SHOW*` and `ShouldShowRefsFilter`: hidden tag,
local and remote labels stop retaining their commits in graph modes. HEAD remains
visible even with its local branch label hidden. Stash and Bisect labels keep their
independent always-enabled flags. Other refs (including Notes) can be hidden from
painted labels, but do not retain commits in labeled-only history even when shown.
Full reference metadata stays attached to entries for revision actions and search.

The Core regression covers all six mask categories, retained HEAD, unknown/Notes
refs, graph bridging and unchanged parent/reference metadata. A native receiver
uses actual annotated tags, local and remote branch refs and another ref on
separate commits. It inspects the attributed label cell before/after hiding,
checks normal-row/selection preservation, reopening preferences and repository
isolation, actual labeled/compressed rows and edges, closed/busy refusal and exact
HEAD/index/working-file preservation. Its preference domain is private and removed.
See [the label QA record](qa/log-label-visibility-2026-10-07.json).

The View menu's Gravatar command now has a partial native implementation; see the Gravatar section below. Footer ordering now places All Branches before Walk Behavior and View;
exact displayed spacing, physical menu interaction, color/layout and accessibility
acceptance remain pending.

## View → unrelated changed paths

View now has Hide Unrelated Changed Paths and Gray Unrelated Changed Paths before
Show Unversioned Files and Labels, matching upstream order. Gray starts enabled
for each new Log; these two modes are mutually exclusive and selecting the active
mode returns to showing all paths. Mode changes act on loaded file details without
reloading history. Hiding a selected file prunes its selection and selection mark;
existing commands refuse hidden rows. Whole Project bypasses the scope styling.

Literal prefix matching follows `FillLogMessageCtrl`, including old paths for
renames/copies and directory/submodule boundaries. Multiple native scopes form a
union. Directory types come from working filesystem attributes or pinned Git tree
modes; bare Git administration directories are not used as working directories.
Git path UTF-8 bytes are compared without case folding or Unicode normalization.
The complete changed-file list is retained. In particular, working-tree details
no longer discard unrelated tracked paths before Gray/Hide can act. Unversioned
paths are inserted independently of the unrelated-path mode, as upstream does.

All five file columns now use the pinned CColors roles and saved preferences:
Modified (including type changes), Added (including scored copies), Deleted
(including missing), Renamed (including rename scores) and Conflict. Renamed is
source blue rather than the former generic brown. Gray overrides action color
for unrelated paths, and selected text uses native primary color. Native dynamic
colors follow the source HSL dark conversion; the Log view subscribes to Apply
notifications. The [Log color QA](qa/log-status-colors-2026-10-09.json) checks
exact defaults and saved custom Modified/Renamed values in the real historical
path fixture on Apple and bundled Git, retaining working-tree/filter guards.
Physical rendered repaint, theme/selection contrast, graph/label colors and
remaining color settings still need verification.

Core checks exercise literal special/Unicode/newline prefixes, Unicode byte
inequality, directory-prefix collisions, gitlinks, rename/copy origins, toggle
states and directory typing in a real bare repository. The native receiver checks
a real rename out of a scoped folder, historical and working tracked paths,
mode/selection/clipboard guards, color choices, Whole Project bypass, unversioned
controls, hidden hosted menu construction and repository bytes. See
[the path View QA record](qa/log-path-view-2026-10-07.json). Physical menu and color
appearance acceptance, richer path-filter expressions and multi-revision file
aggregation remain pending.

Show Unversioned Files now defaults to enabled in both Commit and Log, matching
upstream `AddBeforeCommit`. Both dialogs read and save the same application-wide
preference, so reopening either dialog uses the last choice made in the other.
Existing open dialogs retain their own current switch state. Log updates loaded
working rows without a history reload; Commit filters its loaded status list.
Busy/closing guards refuse preference changes. The native receiver uses a private
preference domain and real tracked/untracked files to check default visibility,
hide/show, reopen in both directions and exact repository preservation. See
[the shared unversioned QA record](qa/shared-unversioned-2026-10-07.json).

## View Patch

View → View Patch now opens a separate native read-only patch viewer that follows
the Log selection. The existing unified viewer supplies syntax coloring, search,
Save As and printing, with staging/applying disabled. The child belongs to the Log
and closes with it. The repository-local `tgit.logshowpatch` setting stores the
choice and reopens the panel for a new Log. Closing the patch window also disables
the setting, including while the parent Log is busy.

`FillPatchView` semantics are separate from the manual unified-diff command: one
revision with no selected file rows shows first-parent changes with statistics;
selected versioned files concatenate individual patches in list order using each
row's merge-parent index and both rename paths. Unversioned rows produce no patch.
Multiple/no revisions clear the view. Root commits and unborn working trees give
an empty preview, matching the upstream comparison behavior. Working previews pin
fresh HEAD and preserve the index. External diff/text conversion tools are disabled.

Selection and file/filter changes cancel prior work and coalesce through a 100 ms
delay. Reload and close cancel owned reads; generation and selection checks keep
late completions from updating the viewer. Busy/error indicators appear in the Log.
The native receiver holds real model reads across selection changes and close to
verify stale output is discarded, and creates/owns an actual hidden read-only
patch child to check data, disabled applying, reopening and close behavior.

Core checks cover whole statistics, literal selected-file bytes, working changes,
unversioned omission, roots, cancellation and exact HEAD/index preservation. See
[the patch preview QA record](qa/log-patch-preview-2026-10-07.json). A further real
merge fixture verifies selected rows from both actual parents, visible-order
concatenation, both rename paths (including literal pathspec syntax and newline),
raw invalid-UTF-8 patch bytes, binary-file markers and configured zero context.
It deliberately clears the caller’s cached parent list and checks that previews
still resolve actual parents. Whole preview bytes match first-parent diff-tree
output; HEAD, index, config, notes ref and working bytes remain unchanged. See
[the merge and byte QA record](qa/log-patch-metadata-2026-10-07.json). These are
Core reader checks, not viewer Save As acceptance. Actual signed-commit metadata,
binary/invalid-UTF-8 viewer exports, displayed alignment and moving/resizing,
keyboard/physical menu/light-dark/VoiceOver and signed sandbox acceptance remain
pending. Full Log acceptance remains incomplete.

View Patch visibility now changes immediately even if remembering the repository
setting fails, matching upstream's independent create/destroy behavior. Failed
persistence is shown separately from a patch-read error; it does not set Log busy,
close a usable viewer or prevent hiding it. Preference writes are ordered so rapid
show/hide/show sequences finish with the last requested setting. A real config-lock
receiver case checks usable open/close, exact config and owned-lock preservation,
recovery after removing the lock and ordered rapid toggles. See
[the preference failure QA record](qa/log-patch-preferences-2026-10-07.json).

The native patch viewer now aligns to the Log frame height when opened. It uses
available screen space on the right, then the left, and otherwise clamps the
initial frame to a visible screen. Negative monitor coordinates are supported.
As in `PatchViewDlg`, a docked viewer follows parent movement and aligned vertical
edges follow resizing. A dragged-away viewer stays at its independent position;
within five points of either docking edge it snaps back. The native gap is eight
points. Log retains ownership without a Cocoa child-window relationship that
would force detached windows to move. Showing/restoring the parent raises the
preview without activating it; parent minimization hides it, and closing Log
still closes its owned preview.

The native receiver exercises deterministic initial-placement/bounds cases and
actual hidden NSWindow move/resize and snap/detach notifications. See
[the placement QA record](qa/log-patch-placement-2026-10-07.json). Displayed screen
transitions, minimization/restoration, Spaces/fullscreen, manual drag/resize and
VoiceOver acceptance remain pending; geometry checks do not prove visual parity.

The first actual-frame check found SwiftUI changing the patch window's minimum
height to its content fitting size. Patch hosting now disables automatic sizing
limits and keeps the explicit resizable window minimum, so the patch text scrolls
rather than forcing a taller window. This uses the macOS 13+
[NSHostingController sizingOptions API](https://developer.apple.com/documentation/swiftui/nshostingcontroller/sizingoptions).
The original failed frame check and diagnostic frames are retained in QA logs.

## Gravatar

View → Gravatar reserves a native author-picture area on the right of the message
pane. Only a single ordinary commit supplies its author email; empty, working-tree
and multiple selection clear the picture. The visibility choice saves separately
for each repository. An unset choice inherits Settings → Dialogs → Enable Gravatar,
which starts off. Existing saved choices keep precedence over that global default.
The URL field uses the source default `https://gravatar.com/avatar/%HASH%?d=identicon`;
all `%HASH%` occurrences are replaced. Email whitespace is trimmed, text lowercased
and UTF-8 bytes hashed with SHA-256 by default. The source MD5 compatibility option
is also available. URLs must have an HTTP(S) scheme and a host; macOS transport
security still applies to custom endpoints.

CryptoKit replaces WinCrypt, URLSession replaces WinINet and SwiftUI/AppKit replaces
the picture box. Each selection owns a delayed 500 ms request; another selection,
disabling the feature or closing the Log cancels it and rejects stale completions.
As upstream does, a previous picture remains until a new request succeeds or fails,
while an empty selection clears immediately. Failed/non-200/empty/invalid image
responses clear the picture without interrupting Git work. Decoded downloads are
limited to 8 MiB. Successful images cache for seven days in an app temporary
subdirectory. Native cache keys include the full request URL so switching custom
providers or hash modes cannot reuse the previous provider's image. Cache-write
failure keeps a usable downloaded picture. These are explicit macOS adaptations.

A headless receiver uses a mock URLProtocol transport, including delayed completion,
to check SHA-256/MD5 vectors, repeated placeholders, normalized and empty addresses,
URL scheme refusal, default-off/no-request behavior, actual image decoding, cache
hit/expiry, HTTP failure, multiple-selection clearing, cancellation/stale completion,
repository/global preference precedence and hidden native Log layout. Its Git
fixtures preserve exact tracked/index/config/HEAD bytes. No repository email hash
is sent externally by these tests. See [Gravatar QA](qa/log-gravatar-2026-10-07.json).

Displayed image scaling/placement, physical View/Settings interaction, custom URL
history, full source temporary-file cleanup controls, real provider/redirect/TLS
behavior and signed sandbox/network acceptance remain pending. No screenshot or
App Store acceptance is claimed; the complete Log and application ports remain
incomplete.

## Compressed graph Expand/Collapse

A single ordinary revision in Compressed Graph now offers Expand or Collapse
before Copy to clipboard. Active text searches suppress the command, following
`IsFilterActive`; empty/inversion-only and invalid ECMAScript expressions remain
inactive. The existing C++ matcher determines regular-expression activity rather
than substituting Foundation's different regular-expression syntax. Date/path
walk bounds still restrict the loaded history. Busy, multiple/working selection,
normal/labeled graph mode and closed Log models refuse rollup changes.

Expanded state propagates down a linear segment until a label, merge or fork.
Those boundary nodes retain their own state. Expanding a merge reveals each
linear parent arm; a fork stops inherited expansion. Per-hash overrides follow
the source toggle rule: reversing a forced state removes that override, while an
explicit choice matching its current default can be retained for later topology
changes. Choices last for the Log session. Refresh applies a snapshot of the map,
so a superseded read cannot overwrite the current projection.

Graph copies bridge omitted ancestors, while action/detail entries retain their
real parent hashes. Collapsed nodes draw a hollow circle or junction square;
node-connected edges stop at its border. Expanded nodes retain the filled shape.
This is a native adaptation of `paintGraphLane`, not a claim of exact GDI rendering.
The menu command has no invented replacement artwork: the pinned command supplies
no dedicated icon. Graph accessibility state and exact geometry still need review.

Core fixtures cover label/merge/fork boundaries, merge-arm expansion, forced
mid-segment collapse, reverting overrides, actual parent preservation and ignored
overrides in normal mode. Search tests use the pinned C++ helper for empty,
inverted, valid and invalid patterns. Native receiver verification and remaining
acceptance are recorded in [rollup QA](qa/log-rollup-2026-10-07.json).

Projection still operates on the loaded revision batch. Cross-page rollup behavior,
compressed/search combinations, malformed/out-of-order topology, physical menu and
light/dark graph appearance, keyboard/VoiceOver and signed sandbox acceptance
remain pending. The full Log and application ports remain incomplete.

## Revision double-click preference

Settings → Dialogs now includes the source checkbox **Can double-click in log list
to compare with previous revision** (`DiffByDoubleClickInLog`), off by default.
The revision table's native double-action selector reads it for each activation,
so changing the setting affects already open Logs. The earlier unconditional
unified-diff double-click action is replaced by the source parent-comparison
handoff. Explicit context-menu unified diff remains available independently.

The first selected row in visible order supplies the comparison origin, including
multiple selection, as `DiffSelectedRevWithPrevious` does. A commit compares with
its first actual parent, including when compressed graph rows hide that parent;
a working-tree row uses its captured HEAD. Roots and unborn working trees offer
**No previous version.** rather than inventing an empty-tree comparison. A native
informational sheet is used when the Log owns a window; headless/no-sheet cases
use the existing navigation notice. Busy/closed and an occupied unified viewer
refuse the handoff. Native settings save immediately through UserDefaults rather
than the Windows Apply button.

Programmatic double-action routing and actual revision pairs, defaults/live
changes, merge/root/working/multiple selection, guards and repository preservation
are recorded in [double-click QA](qa/log-double-click-2026-10-07.json). Physical
pointer timing, clicked/selected ordering under modifier gestures, Shift alternate
tool selection, follow-rename/path-specific comparison factories and displayed
settings/sheet/keyboard/VoiceOver/signed acceptance remain pending. This is partial
Log parity; the full application port remains incomplete.


## First-lane branch revision counter

The native single-selection message header now appends `Branch RevNo: <count>`
when Display branch revision number (`ShowBranchRevisionNumber`, default false)
was enabled when opening Log and the selected node is in native graph lane zero.
The count is Git's first-parent walk, not the total reachable commit count and not
a unique revision identifier. Selection clearing, multiple selection, working-tree
rows and side-lane nodes omit it. Generation checks discard stale detail reads.

This adapts LogDlg.cpp's active-first-lane gate. Native graph layout is not yet
proven identical for all filtered, compressed and all-ref histories; the feature
uses the native first lane rather than claiming complete Lanes equivalence.
[Counter QA](qa/branch-revision-number-2026-10-08.json) records four-Git real merge
history, displayed-message model and rapid-selection checks. Hidden settings
layout does not establish physical toggle, themes, accessibility or signed runtime.
See [Push parity](PUSH-PARITY.md) for the matching post-transport counter.


## Configured log message font

Settings → Dialogs → Font for log messages now applies to the message details
pane, matching `LogDlg.cpp::SetupLogMessageViewControl`. This call targets
`IDC_MSGVIEW`; the revision table has the separate opt-in described below.
The changed-file list keeps its existing native font. The setting shares `LogFontName`/`LogFontSize` with Commit, Merge
and Rebase. Menlo replaces Consolas on macOS, with the source default of 9 points.
Changing preferences updates an open pane and retains its selected text.

The read-only native `OutputView` opts into this setting explicitly. Other output
views keep their existing 12-point system monospaced font. See
[Log/Rebase font QA](qa/log-rebase-font-2026-10-08.json) for actual hidden native
pane checks. Physical font-control interactions, light/dark composed appearance,
rich-message links/styling and the complete Log dialog remain partially verified.


## Optional font for the revision list

Advanced → `LogFontForLogCtrl` now enables the shared log font for the native
revision table, matching `GitLogListBase.cpp::InsertGitColumn`. It defaults to
false. With it enabled, text columns and reference-label text use the selected
font, HEAD keeps a bold face when available, and row height follows native font
metrics with a 24-point minimum so text is not clipped. Font preference changes
reload the cells without changing the displayed revision set. Disabling the
option restores the existing table typography and 24-point rows.

After building Debug, `python3 scripts/test-log-table-font.py` checks an actual
hidden table using two real Git commits. It verifies default-off behavior, enable,
live size change, disable, HEAD bold, message attributes and font-aware row height.
Column autosave is disabled only in the isolated fixture. See
[revision-table font QA](qa/log-table-font-2026-10-08.json). Physical Advanced
editing, selection/scroll/column-layout preservation, visible graph composition,
light/dark appearance and all shared GitLogListBase consumers remain unverified.

## Reference and graph color follow-up

The Log now uses saved pinned CColors reference roles with opaque backgrounds
and source weighted contrast text, plus eight BranchLine colors and saved line
width/node size. Native Settings adds a Log tab with reference/graph wells and
source geometry ranges/defaults. The existing native revision table subscribes
to Apply and accessibility display option changes and reloads its cells, with
private defaults shared by labels and graph cells. See
[appearance details](APPEARANCE.md) and [palette QA](qa/log-palette-2026-10-09.json).
The source lane state machine, lane-index/active-merge colors and native
gradient/shape painting are now adapted as described below. Complete filtered
topology and label borders/tracking shapes/symbolization still need source parity; physical contrast and signed
acceptance remain pending. Named accessibility appearances alone do not enable
system Increase Contrast on this host; native providers use the actual flag.

## Lane state and native graph painting

Normal graph rows now carry the pinned Lanes states rather than drawing the
previous compacted parent curves. Native Log/Blame painting uses empty-slot
reuse, joins, tails, crosses, merge/initial nodes, source lane-index colors,
active merge gradients and source line/node dimensions. Rolled nodes have
source one-point outlines and leave gaps in crossing lines. Synthetic
working-tree rows have no painted graph, matching the source empty-hash gate.

The independent [lane oracle](qa/history-lanes-2026-10-09.json) verifies exact
state snapshots and active columns, including first-parent merges, boundaries,
octopus/disconnected/criss-cross histories and deterministic random DAGs.
Graph projection keeps actual commit parents separate from display parents.
Existing abstract edges remain a compatibility connectivity representation;
they are no longer used for native painting. Shared GraphCell reacts to Apply
and accessibility display revisions for Log and Blame.

Compressed/labeled visibility now preserves full-walk lane snapshots,
including hidden records, and its forced-rollup logic is compared with the
pinned source filter block. Native text search now carries match flags over the
raw walk. Path-simplified Git metadata remains a separate parity task.
Boundary metadata loading now follows the source advanced setting and minus
mark; see the boundary history section below. Source drawing coordinates/gradients are adapted to Core
Graphics; physical raster, selected-row contrast, Retina, scroll/clipping and
signed acceptance still need review. No new screenshot is supplied here.

## Hidden-row walk and full-view rollup

Upstream `LogDataVector::append` advances lane state even when a record is
hidden. Projection now snapshots the full input walk before selecting visible
rows; hidden merges/forks therefore retain their lane assignment at the next
shown row. Actual commit parents and the compatibility display-parent edges
remain separate from the painted lane states.

Collapse/Expand is available in both complete and compressed views, with the
existing single-selection/busy/closed/active-search guards. Complete view honors
forced collapse until a label/merge/fork boundary, which stays expanded by
default there; compressed boundaries stay collapsed by default. Labeled-only
view ignores forced overrides. Label changes trigger a reload when any forced
states exist, even in complete view. Source checks and hidden native menu/Git
acceptance are recorded in [projection QA](qa/history-projection-2026-10-09.json).
Physical graph/scroll/selection contrast and complete search/path walker
metadata equivalence remain unverified.


## Boundary history endpoints

The existing Advanced setting `LogIncludeBoundaryCommits` now takes effect when
opening a Log, matching the upstream constructor's default false and saved
registry value. The native Log captures its UserDefaults value at construction.
Enabling it adds both `--left-right` and `--boundary`, as `CGit::GetLogCmd` does
for LOG_INFO_BOUNDARY. Git's `%m` field travels separately from the full commit
hash; only its minus mark sets `LogEntry.isBoundary`, matching
`GitRevLoglist::IsBoundary`. Left/right marks are ordinary commits.

Both direct layout and compressed/labeled projection pass that boundary flag
to the source lane state machine. The excluded endpoint keeps its actual
parents, full message and file-detail eligibility; a boundary symbol does not
replace commit identity or action parents. Disabled and ordinary complete walks
retain their previous scope. The Advanced choice is read when opening a new Log,
rather than adding a different checkbox to the source Walk Behavior menu.

Real difference and symmetric-difference fixtures check excluded endpoints,
full-history and ordinary parent metadata, real file details and unchanged
HEAD/index/config/working files. The compiled pinned C++ projection oracle now
includes boundary rows alongside normal, compressed, labeled, forced-rollup,
reference-mask and first-parent combinations. Native model checks use private
preferences on both Git engines. See [boundary QA](qa/history-boundaries-2026-10-09.json).
Physical boundary raster/Retina/selection, search/path combinations and signed
sandbox acceptance remain pending; this does not establish full Log parity.


## Working-tree row preference and file-list font

LogDlg's source LogIncludeWorkingTreeChanges is default true and combines with
a non-bare checkout and the caller's ShowWorkingTreeChanges flag. Native Log
now captures that saved preference when constructed, uses it to initialize the
working-tree choice, and keeps it as a read gate. A disabled Advanced preference
cannot be bypassed by setting the native runtime checkbox. Normal Logs can still
hide the row; revision pickers and bare Logs never add it. This corrects a stored
setting that previously had no effect.

The changed-file Table now uses LogFontForFileListCtrl (default false), with the
same configured log font used by source GitStatusListCtrl::Init and
FileDiffDlg::OnInitDialog. It is independent of LogFontForLogCtrl, which still
controls the revision table. The shared status/file table modifier covers the
other status dialogs, including both Commit staging lists; native Add also
updates text/row frames. Autosizing uses the selected file font rather than
always measuring the system font. Changing fonts does not change the file data,
checked paths or selection.

[The native list preference QA](qa/log-list-preferences-2026-10-09.json) covers
real history and dirty/untracked files with private defaults, Log/Commit row
heights, native Add text fonts/frames and checkbox/highlight preservation,
font-aware Commit column sizing, and enabled/disabled/picker/bare working-row
gates on both Git engines. Other consumers are wired through the shared modifier
and checked by compilation/source review. Physical raster, all-dialog interaction,
header font equivalence, extreme font sizes and signed sandbox remain unverified.


## Search-hidden raw walk and Follow graph visibility

The source worker computes compressed/forced visibility first, applies its text
filter next, then calls LogDataVector::append even for hidden records. Native
Log now requests retained raw rows, applies its raw batch limit in Git, and
carries matchesHistoryFilter separately from commit identity and parents. It
uses the same display matcher for literal, compound and regex search rather
than removing literal matches through Git grep before graph construction.
CommitGraph updates rollup/children/lanes across all raw records, then combines
source visibility with the match flag. The source synthetic working row stays
outside the text filter, as it is added before the worker's commit loop.

Search-hidden HEAD can therefore still expand ordinary ancestors; a hidden
collapsed label still suppresses its segment. A displayed match keeps the raw
walk's active lane instead of becoming a new branch solely because earlier rows
were filtered. Invalid regex activity and original action/detail parents remain
unchanged. The public match-only Core history API keeps its prior behavior;
retainFilteredRows is the native Log's explicit raw-walk contract.

RevisionTable also reloads graph cells when snapshots change while displayed
hashes remain identical. Follow renames hides the graph column as the source
end-of-loading ShowGraphColumn call does; disabling Follow restores the saved
column visibility. The graph header choice is disabled while Follow forces it
hidden, and column reset respects that state.

The compiled pinned C++ visibility/rollup/filter-order/lane oracle adds all,
alternating and no-match masks to boundary/first-parent/reference/forced cases.
Real Core and native Git fixtures check raw count limits, literal/compound/regex/
invalid modes, forced inheritance, boundary/action/file preservation, existing
menu guards, same-identity graph refresh and Follow hide/restore. See
[search-walk QA](qa/log-search-walk-2026-10-09.json).

The initial raw 200/Show next 200 scope recorded at this checkpoint is
superseded by the count/date/no-limit scope below. Streaming, match highlighting,
physical Windows/macOS raster/Retina/scroll/keyboard, all search/path combinations
and signed sandbox acceptance remain pending. This does not establish full Log
or application parity.


## Default history limits and From/To controls

The native Log replaces its fixed 200-record batch and Show next 200 button with
the pinned source's No limitation default. Dialog settings offer the six source
choices, in order: No limitation, Last selected date, Last N commit(s), Last N
year(s), Last N month(s), and Last N week(s). The numeric field is blank and
disabled for the first two. Apply saves the selected scale and only a positive
parsed number; invalid, zero and negative input retain the saved number. Cancel
restores the saved values. These controls use a draft, rather than writing each
keystroke to preferences. The surrounding Settings property-sheet lifecycle is
still a macOS adaptation and does not establish full source Settings parity.

Log's From menu offers No limitation, the saved numeric scale when applicable,
and Configure default. Configure default opens the same scope controls in a
macOS sheet. The live window retains its captured number, as the source menu
does. Choosing No limitation removes the repository's saved From date and
ignores its lower bound, while retaining an explicit To bound. From changes
select the date scale, clamp to To and use local midnight. To changes clamp to
From and include the day's final second. From is saved per repository only when
Last selected date is the configured default. Explicit revision callers ignore
the initial date/relative default but preserve a saved commit-count limit.

Relative years, months and weeks use the source's fixed 365-, 30- and 7-day
intervals, anchored at local midnight, including the source DWORD cast before
signed subtraction. They are not calendar-month/year subtraction. The initial
displayed From/To dates come from the raw loaded committer dates, except for
explicit bounds, matching the source loading handler. Count limits apply to the
raw walk before visibility/search filtering; other scopes remove the count cap.

The Core checks cover saved defaults, repository-specific dates, count/date Git
reads, fixed intervals and a Berlin daylight-saving day. A compiled oracle checks
2,160 scope cases against the pinned GetLogCmd filter body, with injected
local-midnight epochs. The native receiver checks an uncapped 205-commit Log,
range/count/date interactions and actual Settings controls with both Git engines.
See [history limit QA](qa/log-history-limits-2026-10-09.json) for evidence and
final build scope. Streaming and
large-history performance, full Settings property-sheet integration, non-ASCII
Windows numeric parsing, non-Gregorian user calendars, physical date/menu/sheet
keyboard/VoiceOver/Retina behavior and signed sandbox acceptance remain pending.


## Full commit message on each Log line

The preference FullCommitMessageOnLogLine is now consumed by native Log,
Blame history and Rebase's commit list, matching their shared upstream
GitLogListBase constructor. It defaults to false and is captured when each
model is constructed. Existing windows retain their choice; reopen the window
after changing the preference. This key is not one of the source's 52 registered
Advanced Settings entries, so that catalogue is unchanged. The source SetDialogs
page exposes it as **Display subject and body of commit messages**; native
Settings → Dialogs now exposes the same checkbox. Earlier runtime-only notes
missed this ordinary Dialogs setting.

The display renderer uses GitRev/gitdll's raw first-LF subject/body split. Short
mode displays that first line. Full mode appends one space and the remaining
body when present, then replaces every CR and LF with one space. Blank lines,
CRLF's two characters, tabs and other whitespace are retained rather than
trimmed or collapsed. This also avoids repeating a continued heading: Git's
%s summary folds the first paragraph, whereas the source subject is the raw
first line. Synthetic working-tree rows keep their existing descriptive title.

Reference labels retain their styling, and the message remains a single
truncated line. Full raw message, subject metadata, clipboard commands, commit
actions, selection and details are unchanged by this display preference.
Subject and Messages searches now use the same raw first-LF split independently
of the display preference. Git summary metadata remains available for other
operation consumers; it is no longer substituted for source subject filtering.
The Subjects/Messages clipboard actions use source bullet and CRLF formatting
(see the following section). Match highlighting, all-dialog physical appearance
and signed sandbox acceptance remain pending.

For the packaged app, configure the source-equivalent runtime preference with:

```sh
defaults write org.turtlegit.macos FullCommitMessageOnLogLine -bool true
```

Delete the override to restore the default, then reopen affected windows:

```sh
defaults delete org.turtlegit.macos FullCommitMessageOnLogLine
```

[Message-line QA](qa/log-message-line-2026-10-09.json) records the Core raw-message
and whitespace fixtures, real Git multiline-heading case and focused native
Log/Blame acceptance with private preferences. Rebase construction preferences
and plan/selection/action data are checked, but its rendered text is still
unverified: both the production row and a minimal SwiftUI Table reproduction
expose no row text through the in-process accessibility checks in this receiver.
The strict full receiver retains that failing acceptance gate. No new physical
screenshot is implied.


## Raw subject search and clipboard formats

The pinned LogDlgFilter searches the raw subject when either Subject or Messages
is selected, then adds the raw body only for Messages. A continuation line in a
multiline first paragraph is part of the body, although Git's `%s` folds it into
the summary. Native history filtering now follows that split, including CRLF
messages; original full message and Git summary metadata remain intact.

The native Copy to clipboard → Subjects action emits `* `, the trimmed raw
subject and two CRLF separators for every selected revision. Messages emits
`* `, the right-trimmed raw subject, CRLF, the body with LF replaced by CRLF and
trailing whitespace removed, then two CRLF separators. This follows
GitLogListBase::CopySelectionToClipBoard and GitRevLoglist::GetSubjectBody(true),
including the additional subject/body separator for a message with no body.
Selection uses displayed revision order and the display preference does not
change copied content. macOS pasteboard text stores these source CRLFs.

The [search/copy QA record](qa/log-message-search-copy-2026-10-09.json) records
verification scope. Windows locale-specific CString whitespace classification,
physical context-menu interaction, all other clipboard formats and signed
sandbox behavior still require comparison. Existing full-message display QA is
a historical checkpoint; its pending search/copy note is superseded by this
section, without changing its recorded results.


## Search match foregrounds

The native Log prepares match ranges off the UI thread after projecting the
loaded rows, then paints matching text with `Colors.FilterMatch` (source default
RGB 200,0,0). The Log color settings expose this editable role with Apply,
Cancel and defaults; it uses the existing light/dark/contrast color transform.
Reference badge backgrounds and their contrast foregrounds are retained.

Literal ranges follow FilterHelper's positive terms, including quoted terms,
OR terms and overlapping occurrences. Negative terms are skipped; leading `!`
changes filtering, not which positive text can be highlighted. Adjacent and
overlapping ranges merge. Regex ranges use whole ECMAScript matches in UTF-16
coordinates through the bundled helper, with invalid/empty patterns producing
no highlights. Zero-length ranges are represented but paint no characters.

Column gates follow GitLogListBase: revision hashes, author/committer names,
author/committer emails and bug IDs each require their selected filter field.
Unlabeled message cells allow Subject or Messages. A message cell with reference
badges allows Subject in short mode, adding Messages in full-message mode. The
match offsets are relative to the message text, excluding reference badges.
When a revision has refs but every badge is hidden, the source skips custom
message match painting; the native gate follows that early return. Date, action
and graph columns are not match-painted. Ranges refresh even when
loaded revision identities stay the same, and generation checks prevent an old
reload from installing a newer request's colors.

[Highlight QA](qa/log-match-highlights-2026-10-09.json) records the focused checks.
Windows locale-sensitive casing versus Swift/libc++ Unicode casing, complete
source regex-library equivalence, selected-row physical contrast, drawing,
Retina, accessibility and signed sandbox acceptance remain unverified. This
updates the pending Log match-highlighting notes above; it does not establish
all consumers of the shared Windows list implementation.


## Reference placement and symbolization

Native Settings → Dialogs now includes the source **Symbolize ref names**,
**Draw tag/branch labels on right side**, and **Display subject and body of
commit messages** controls, implemented with native AppKit checkboxes and two-way preference
bindings. All three default to false and are captured when a
Log is constructed; reopen history windows after changing them. The full-message
choice also applies to new Blame/Rebase models. These are ordinary SetDialogs
controls, separate from Advanced settings.

Right-side mode places the message before reference labels, as the source does;
labels follow the message's measured/text-flow width rather than being pinned
to the far edge of the column. Long text can therefore hide the following
labels. Left mode keeps the labels before the message. Match offsets remain
relative to message text in both orders. Message tooltips now follow the source
left-label condition and raw first-line subject; right mode has no message-cell
tooltip.

The native label projection reads branch remote/merge configuration independently
of whether an upstream ref currently exists. Co-located upstream labels pair
immediately after their local branch and their later standalone duplicate is
suppressed. Multiple locals can each pair the same upstream, matching the source
loop. Pairing requires visible local/remote categories. Tracking metadata remains
present for missing/diverged or hidden upstream refs; canonical reference names
and commit operation identities are never replaced by shortened label text.

When symbolization is enabled, a single configured remote is omitted from its
labels; its source upstream marker is drawn as a text attachment. A tracking
pair with the same branch name uses `/≡` for a single remote, or `remote/≡` with
multiple remotes. Different-name pairs use the upstream branch, and unrelated
remote labels shorten only at the complete remote-name prefix. Native Log reads
this context during reload and updates label projections even if the revision
hashes remain unchanged.

Ordinary label visibility toggles still redraw without re-reading Git. Cached
match ranges are now independent of label visibility, with the source painting
gate applied live; hiding all labels suppresses custom message matches and
restoring a label restores the foreground. Compressed/labeled and rolled graphs
keep their existing reload behavior.

[Reference-label QA](qa/log-reference-labels-2026-10-09.json) records focused
scope. The subsequent reference-kind checkpoint below adds nonbranch names and
annotated-tag metadata. Exact tracking rounded/double-border joins, annotated-tag polygon shape,
label hit rectangles and upstream context interactions, remaining Settings
property-sheet lifecycle, all shared-list consumers, physical clipping/Retina/
selected-row contrast and signed acceptance remain pending. The native marker
adapts source geometry; no raster-equivalence screenshot is claimed.


Reference kinds and bisect labels (2026-10-09)
------------------------------------------------

History labels now apply the pinned CGit::GetShortName prefix and terminal
peeled-suffix rules for branches, tags, stash, bisect, notes and unknown refs.
Canonical names and commit targets remain separate from display names. The loader
marks annotated tags from peeled reference metadata. Recognized bisect refs use
the configured good/bad terms, with sequential good/bad/skip classification;
unrecognized bisect refs use the Other refs visibility and color roles.

The history-specific terms reader resolves BISECT_TERMS through Git (including
worktree paths) and reproduces two bounded 259-byte reads, LF removal and NUL
termination. Missing files use good/bad defaults; opened empty files yield empty
terms. It reads fresh for history rather than adopting the source's static
five-second cache. Windows file-opening, read-error and invalid UTF-8 decoding
equivalence remain unverified. The existing active-bisect state reader is separate.

[Reference-kind QA](qa/log-reference-kinds-2026-10-09.json) records focused Core
and hidden native checks. This is name/classification metadata parity; annotated
tag polygons, tracking joins, physical screenshots, full Rebase rendered-text
acceptance and signed distribution remain pending. No compiled Windows oracle
is claimed for this checkpoint. Atypical refs/stash-prefixed names are classified
as stash, while the existing color selector still recognizes exact refs/stash;
that broad-prefix color edge remains pending.
