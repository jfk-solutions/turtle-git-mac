# Advanced Settings port audit

Target: TortoiseGit commit `7338078f8ddd924b8cddee35f512f2286072136d`.
The native editor and storage are implemented. Later family checkpoints below
identify delivered consumers and their evidence; complete Settings/application
parity and native visual/gesture acceptance remain open.

## Source and catalogue

- `SettingsAdvanced.cpp`, blob `1b222ebf9053e0e902f79413899dc92d35071464`:
  52 definitions, source order, defaults, Name/Value presentation, Apply and F2/
  double-click label editing.
- `SettingsAdvanced.h`, blob `86f71b16237139ab46530d5ddbc988649f96ae31`:
  boolean and DWORD validation, empty-value removal and changed-value writes.
  Its StringSetting class has no registered settings in this baseline and is
  not implemented by the native catalogue.
- `IDD_SETTINGS_CONFIG`: list followed by the original warning/default-reset text.
- [Pinned catalogue](upstream-advanced-settings.json): all 52 names, types,
  literal/default expressions. The short-hash default is 8, following the pinned
  `CGit::GetShortHASHLength` implementation rather than the user's Git abbreviation.

`AdvancedSettingDefinition.all` preserves this complete registered catalogue.
The native Settings window adds Advanced after the existing tabs, retaining
Appearance as its initial page. Its AppKit table shows Name then Value, keeps Name
read-only, and edits Value on double-click or F2. Column reordering is disabled,
matching the source's fixed displayed order. The source's global settings tree,
page icon and full property-sheet host remain pending.

## Editing and persistence

Boolean input accepts exactly `true`, `false` or empty. Numeric input currently
accepts ASCII decimal digits or empty, including zero and leading zeros, without
a convenience-widget range restriction. Source `_istdigit` locale/non-ASCII
behavior still needs Windows comparison; the current validator does not claim
that broader parity.

Empty input removes the stored override on Apply. Display of a saved DWORD uses
its signed 32-bit representation, matching source `%ld`. Positive conversion
saturates at `2147483647`, following Windows `_wtol`/LONG behavior; this is not
macOS's 64-bit `long` conversion. [Microsoft's `_wtol` reference](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/atol-atol-l-wtol-wtol-l?view=msvc-170)
confirms positive overflow returns `LONG_MAX`. Numerically equivalent input does
not create or rewrite an override. The store validates a changed batch before
writing it; source normally validates each edit before Apply.

The native model holds drafts until Apply and preserves the entered text after
Apply, including blanks and overflowing input, as the source list does. Its
modified state resets and notifies the view. Cancel discards drafts and reads
saved values; window-close notification also discards the page's drafts. Apply
writes only this page's edited rows, preserving changes from existing native
settings tabs that share the same keys. Weak window references and a static
repaint callback avoid retaining the settings window/view through the model.

Apply invalidates open native views so the implemented list-background preference
can redraw. Existing consumers also read completion minimum/parse size/
unversioned parsing/extension removal, commit-message styling and app context-menu
icons and separate Finder menu icons. Finder settings publish on Apply and app
startup through an independent presentation cache; signed handoff remains pending.
See [menu audit](CONTEXT-MENU-ICONS-PARITY.md). Other settings
are stored for subsequent ports; their row tooltips state that they have no
effect yet. Storage/editor parity is not proof of their runtime behavior.

## Verification and remaining scope

The connected [list-selection family](LIST-SELECTION-PARITY.md) adds the
`FullRowSelect` consumer across file, reference, progress and related Settings
lists. Revision-history rows retain their source-forced full-row selection.
Its checkpoint records actual implementation and remaining acceptance.

The connected [Finder status-policy family](FINDER-STATUS-POLICY-PARITY.md)
implements `OverlaysCaseSensitive`, `TGitCacheCheckContentMaxSize` and `BlockStatus`
consumers. Their independent shared record and collection fence publish together
on Apply; blank overrides still restore defaults. The family record tracks
actual validation and remaining native/signed acceptance separately from this
catalogue's historical checks.

Four core tests compare the entire catalogue with the pinned fixture, then cover
strict boolean input, invalid batches without mutation, blank deletion, absent
unchanged defaults, numeric equivalence, zero, leading zeros, overflow and signed
stored DWORD presentation. The most recent full core run, before the menu icon
follow-ups, passed 460 tests with zero failures. Focused follow-up verification
is recorded in the menu audit.

The Swift 6/macOS 13 standalone driver instantiates the actual native table/model
without displaying a window. It verifies all 52 rows, Name/Value order,
read-only/editable columns, fixed order, geometry, cancelled label-edit receiver,
draft Apply/Cancel, default deletion, modified-state notifications, preservation
of another page's changes, zero/overflow and source input retention. CI includes
this receiver check after the Debug app build.

Actual F2/double-click/field-editor gestures, Escape/focus behavior, Apply/Cancel
buttons, window reopening/closing, cross-tab lifecycle, repainting an open
Worktree List, light/dark screenshots, source locale digits and signed acceptance
remain unverified. Full settings navigation and remaining consumers remain part
of the full-app goal. See [verification record](qa/advanced-settings-2026-10-06.json).

SanitizeCommitMsg is now consumed by the shared Commit/Rebase message-file
formatter, using the source default-on ASCII trimming and blank-line rules.
Native commits with verbatim Git cleanup verify that disabling it preserves
blank lines while retaining source per-line trailing-space/CR trimming. See
[message formatting](COMMIT-PARITY.md#commit-message-file-formatting-and-comment-stripping)
and [QA record](qa/commit-message-file-2026-10-07.json). Other consumers and full
settings acceptance remain incomplete.

LogIncludeBoundaryCommits is now consumed when opening a Log. Its source
default false and saved boolean enable Git left-right/boundary output, preserve
full commit hashes and parents, and carry the minus mark into boundary lane
states. The Advanced tooltip now identifies it as effective. Real difference/
symmetric/full-history reads and native private-preference checks are recorded
in [boundary history QA](qa/history-boundaries-2026-10-09.json).


LogIncludeWorkingTreeChanges now gates the synthetic Log row at construction
and history reads, with source default true, a working checkout and the caller's
normal/picker context. Disabling it cannot be bypassed by the existing native
Show Working Tree Changes checkbox. Bare repositories and revision pickers
never add the row. New Logs read the saved setting.

LogFontForFileListCtrl now uses the configured LogFontName/LogFontSize in
Commit, Check for Modifications, Log changed files, revision Compare, Revert,
Resolve, LFS locks, Rebase file/conflict lists and native Add. The application
workspace file table shares this typography. Revision and file fonts have
independent default-off flags; the already implemented LogFontForLogCtrl is
also identified as effective by the Advanced tooltip. File font updates preserve
checked files and highlighted rows. Native Add expands row/text frames and
centers icons; shared status-list autosizing measures the selected font.
See [list preference QA](qa/log-list-preferences-2026-10-09.json). Other consumers,
physical font/raster/keyboard/VoiceOver and full settings acceptance remain pending.


## Full-message preference belongs to Dialogs settings

FullCommitMessageOnLogLine is read by GitLogListBase but is absent from the
pinned 52-entry Advanced Settings catalogue. Native Log, Blame history and
Rebase now capture its default-false value and share the source line renderer.
The Advanced catalogue is unchanged. SetDialogs does expose a normal Dialogs
checkbox, now mirrored as **Display subject and body of commit messages** in
native Settings → Dialogs. Earlier runtime-only descriptions missed that
SetDialogs control and are corrected here. See
[Log message-line configuration](LOG-PARITY.md#full-commit-message-on-each-log-line)
for the native defaults command, exact whitespace behavior and remaining scope.

## Reference/list consumer batch — October 14, 2026

NoSortLocalBranchesFirst now drives natural branch-label ordering in the shared
checkout-reference catalogue. The source compares the displayed remotes/ prefix
when grouping; that includes a local branch whose name begins with that prefix.
Disabling local-first ordering combines branch labels in one natural order. Tags
and other reference categories remain separate and FETCH_HEAD stays a virtual
last item. Shared Switch/Merge/Export/Format Patch revision consumers pass their
preference domain through; other catalogue callers use the app-wide preference.
Native numeric/case-insensitive collation and raw-byte ties replace Windows
StrCmpLogicalW; full Windows-locale equivalence remains unverified.

LogTooManyItemsThreshold now suppresses Log's changed-file list above the strict
source threshold (default 1000), including parent-group headers, and displays
“Too many files to display.” Retained file metadata/counts remain available;
filters do not turn a suppressed oversized list into actionable hidden rows.
The source DWORD/minimum-three rule reads NumDiffWarning for selected-file
comparison launches from Log, Commit, Working Tree and Add, plus Changed Files
comparison and per-file unified-diff launches. Log parent groups share one
confirmation covering the selected rows. Aggregated GNU patches open one viewer
and do not acquire a many-viewer warning. Pending questions hold captured files,
operation/Quit ownership and the lease; No opens nothing and retired Yes cannot
open windows. The old TurtleGit.NumDiffWarning alias is read only when the source
key is absent. Advanced displays the effective legacy value; editing or clearing
it removes the alias so Reset restores the actual source default.

These three entries now have effective-consumer tooltips. The same audit also
corrects obsolete no-effect tooltips for the existing superproject pointer, named
remote fetch policy, LFS list-position restoration, commit sanitization, squash
date, styled output and release-check/preview consumers. This does not imply
that every registered Advanced preference is consumed. All fifteen affected
Core checks and six grouped native consumer/remote/settings receivers passed
with system and bundled Git, and all were reaped. A native-only tooltip audit
rebuilt the changed app file without repeating Core tests. See
[actual results and limits](qa/advanced-list-consumers-2026-10-14.json). Physical sheets, every diff-entry caller and Windows locale/signed
acceptance remain open.

The shared [rename/copy detection family](DIFF-DETECTION-PARITY.md) now connects
source percentages, paired file/patch reads, pinned snapshot policy and historical
cache invalidation. Its separate validation record reports the actual scope.

The connected [Log reference-navigation family](LOG-REFERENCE-NAVIGATION-PARITY.md)
adds source reference-set scopes, multi-tip/range picking, bounded exact recents
and owned browser/preparation lifetime. ChooseVersion histories remain session-only.

## Shared conflict identity family — October 15, 2026

The [shared conflict identity reader](CONFLICT-IDENTITIES.md) supplies captured
operation/branch captions and the default-on guessing policy. Text/image panes,
delete/modify and submodule sides and external merge-tool arguments share the
same stage mapping. The Advanced disable-guessing setting now has a runtime
consumer. Existing source-control mappings and complete-dialog acceptance remain
partial; earlier generic-label gaps are superseded within this documented scope.

[Grouped validation and visual review](qa/conflict-identities-2026-10-15.json)
record actual coverage and remaining limits; no dialog is newly certified.

## Captured transport/progress presentation — October 15, 2026

The [connected presentation family](TRANSPORT-PRESENTATION.md) now consumes
FetchVerbose and DownloadAnimation without extra dialog controls. It shares the
source byte-limit interpretation across Clone, Push and common progress. The
pinned ProgressDlgLinesLimit entry remains dormant, with no invented consumer.
Full workflow, physical and signed acceptance remain partial.

[Grouped evidence](qa/transport-presentation-2026-10-15.json) records 33 affected
Core cases, the Debug build and four native groups on both Git engines, including
the argument-recorder setup repair. Complete hosted/physical/signed parity is
not established.

## Independent cache menu — October 16, 2026

CacheTrayIcon now publishes an optional helper-owned menu-bar interface, source
counts and a fifteen-line activity window. Apply/Cancel and application-menu icon
preferences share the existing settings transaction. The helper observes accepted
configuration changes; disabling the icon retires its visible activity and stale
menu actions. See [cache menu](CACHE-MENU.md) for native adaptations and deployment
limits. Other dormant Advanced entries are not implied to have new consumers.

The [checkbox index family](COMMIT-CHECKBOX-INDEX.md) now consumes the default-on
ReaddUnselectedAddedFilesAfterCommit preference in native checkbox Commit attempts.
Staging mode is unaffected. Other dormant preferences retain their existing status.

## Conflict-list refresh consumer — October 16, 2026

RefreshFileListAfterResolvingConflict now controls the explicit status/Commit/
Resolve list callbacks after conflict-editor and Resolve outcomes, using the
source default true and exact DWORD equality to 1. Actual resolution and its
post-operation status read, Rebase state, Log/repository notifications and explicit
F5 remain independent. The Advanced tooltip identifies the consumer. See
[Resolve interaction](RESOLVE-PARITY.md#file-drops-source-keys-and-parent-refresh--october-16-2026).


## URL/path input word commands — October 17, 2026

[Input word navigation](INPUT-WORD-NAVIGATION.md) now consumes
`UseCustomWordBreak` in the connected native path, Commit branch/author, Clone/
Fetch history and Bisect revision controls. Its source plain/combo modes, Cocoa
movement/extension/deletion, native editing and remaining standalone/mouse/locale
scope are explicit. This supersedes the no-consumer status for those controls.


## Optional remote-reference engine — October 19, 2026

The [remote-reference workflow continuation](REMOTE-REFERENCE-ENGINE-PARITY.md)
connects source-selected libgit2 reference/tag reads and remote-ref deletions,
including the branch picker's source-specific HEAD choice, captured native
preferences and post-delete refill. Ordinary Push stays on its CLI source path.
Actual grouped evidence and remaining certificate-cache, public/signed/physical
and complete source acceptance are recorded with that family.


### Historical materialization continuation — October 19, 2026

The [historical file family](HISTORICAL-MATERIALIZATION-PARITY.md) connects the
source default GetOneFile backend to historical opening/editors, Save As and
selected/recursive output. Accepted operations retain their engine choice through
panels and delayed file delivery. Raw comparison and Blame readers remain distinct;
source filter semantics and actual grouped evidence are recorded in that family.

## Finder cache persistence and live-session family — October 19, 2026

`CacheSave` now controls the connected app/extension/helper cache lifecycle. Its
source default true gates warm restore/save, while live IPC, active badges and
watched permissions remain independent. Apply publishes the shared policy; failed
publication retains the saved choice and durable retry eligibility across Settings
reopening. Startup republishes the choice. Owned sessions, process-exit fencing,
retired-read refusal, owner-aware removal and helper diagnostics/retry are described
in [cache persistence](FINDER-CACHE-PERSISTENCE.md). Other dormant entries retain
their own consumer status; this does not certify full Settings or Finder parity.
