# Rebase Conflict Files

When Rebase or Cherry Pick stops while applying a commit, the lower file tab
becomes **Conflict Files**. It lists conflicted and clean tracked changes with
a checkbox, Path, Extension, Status, Lines added and Lines removed columns. Original
TortoiseGit status icons and colors identify each file.

The selected unresolved files offer **Compare with base**, **Resolved**, and
choices using the commit being replayed or the branch being rebased onto.
Compare uses Git's stage-1 base rather than destination HEAD. The replayed side
is stage 3; the destination side is stage 2. **Edit conflict…** and double-click
open the existing text, delete/modify or submodule conflict editor for a single
unresolved path. Resolution uses the existing Resolve workflow and refreshes the
parent replay window.

Resolved changes remain in the file tab until the replay step advances. Reopening
the dialog also recovers them from Git's state. An Edit action that conflicts has
not yet reached its applied Edit pause: Split remains unavailable, and Continue
does not amend the destination commit. Once Git actually pauses after applying
an Edit commit, the multiline editor and [Split workflow](REBASE-SPLIT.md) become
available.

## Checked Continue for Pick and Edit

All listed files start checked. Uncheck files to exclude them from the first
resolution commit; row highlighting and checkboxes are independent. The Commit
Message tab lets you edit the resolution message. Continue requires every conflict
to be resolved and commits the checked whole-file contents against destination
HEAD using a separate index. It retains the source author and original author-date
timezone and leaves unchecked index entries and working contents available.

When tracked changes remain, the full native Commit sheet opens in Amend Last
Commit mode, comparing against the applied commit. It keeps amending that commit
until the tracked tree is clean, matching upstream's non-Split recovery loop.
The continuation record captures the replay step, entry ID and expected HEAD.
Cancel preserves the applied commit and remaining changes; reopening and Continue
return to the amendment sheet. Stale sheets and dirty automatic continuation are
rejected. Post-actions and new-branch/amend-mode changes are disabled.

A recovered Edit pauses for multiline message approval after the amendment loop.
A recovered Pick resumes replay once the tree is clean. Split can subsequently
divide an applied Edit commit through the separate Split workflow. Cancelling
the first Split dialog restores the applied conflict Edit pause and message,
including after reopening. A rejected
Edit message leaves the continuation record intact for retry.

Empty results now offer Commit/Skip/Cancel, and conflict messages have an
Ignore/Abort hint warning. See [empty results and message hints](REBASE-EMPTY-RESULTS.md).

## Remaining parity work

This is a partial port of upstream's conflict tab. Squash checkbox acceptance
the Strip Commented Lines preference, all contextual
commands and full displayed layout/keyboard/accessibility acceptance remain
pending. Squash conflicts keep the existing staged Continue
path, and their checkboxes are disabled. Single ordinary base comparison now
uses the full native editor; multiple paths and unavailable stage-1 cases retain
unified output. No new screenshot establishes this tab's displayed layout.

## Verification

Focused Rebase tests cover checked resolution and recovery,
including conflicted Edit, resolved-before-Continue recovery, premature Split
rejection, unchecked index/content retention, amendment without extra commits,
stale/unresolved/empty selection rejection and destination history preservation.
The headless native receiver hosts the actual six-column table and drives the
real replay and quick Resolve models. It checks clean/conflicted rows, a path
containing Unicode and a newline, stage-1 comparison, single-path Edit routing,
replayed-side resolution, parent refresh, resolved-row retention/reopening,
checkbox-selected commits, amendment sheet Cancel/reopening, Edit message
approval and final Continue. Editor handoffs and confirmation answers are
injected; displayed
editors and user gestures are not established by this receiver.

Pinned upstream: `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseProc/RebaseDlg.cpp` (`UpdateCurrentStatus`, `REBASE_TAB_CONFLICT`
and conflict context-menu handling). Evidence:
[QA record](qa/rebase-checked-continue-2026-10-06.json).

Squash now lists all group files relative to the destination parent and continues
through staged resolution and combined-message approval.
See [Squash conflicts](REBASE-SQUASH-CONFLICTS.md).

Empty Squash groups now offer Commit/Skip/Cancel and recover an approved Skip
after failure. See [empty Squash groups](REBASE-EMPTY-SQUASH.md).

## Conflict file menus and native base review — 14 October 2026

The source status-list mask includes read/open/history/export/clipboard commands,
while excluding Commit, Restore and Changelists. The native conflict list now adds
Open, Open With, View revision in alternative editor, Show log (including an old
name when present), Blame, Reveal in Finder, Export and Compare two files with
original icons and selection/type conditions. Full paths, relative paths,
file/folder names, all five displayed columns and individual column copies retain
the visible row order, Unicode and literal newlines. Extension cells now use the
shared source dotted extension format. Command/Control-C copy paths; Shift adds
status. Space toggles checked rows independently of highlighting, only when the
lower conflict table owns focus and checked continuation is supported.

A popup captures its displayed rows, stages, statistics, stopped replay identity,
HEAD and refresh generation. Preparation holds its token, permission and global
Quit lifetime through any chooser or command settlement. It validates the current
session before routing; Open With and Export validate again after the chooser.
Later highlighting cannot redirect an old selection, and refresh/retirement cannot
revive a stale popup or picker. Export uses the existing cancellable working-file
copy backend and keeps the chosen destination grant until it settles.

Single ordinary Compare with base now opens the native two-pane editor using the
captured stage-1 blob and current working bytes. Its working pane can edit/save
through existing encoding, backup, empty-result and stale-byte/stage guards without
staging. The Rebase owner retains the viewer and blocks replay actions until it
closes, then refreshes the actual session. Multiple/unavailable-base comparisons
retain the existing unified output. Clean tracked rows double-click into ordinary
working comparisons; unresolved single rows retain Edit conflict.

[Grouped native evidence](qa/rebase-conflict-menus-2026-10-14.json) records actual
private clipboard/export/owned picker and comparison behavior separately from
injected Open/Editor/Log/Blame/Reveal callbacks. Core is unchanged in this batch.
The remaining source status-list menus (including broader submodule history,
Add/Ignore/Delete and prepared/unified comparison combinations), drag/drop, all conditional layouts, physical keyboard/VoiceOver,
broader editor-dispatch conditional/physical cases and signed Finder/sandbox acceptance remain
open. This does not certify full Rebase, Cherry Pick or app parity.

Workspace editor dispatch now also owns cancellable preparation across its four
specialized routes and external tool handoffs. See
[the routing family](DIFF-TOOLS-PARITY.md) for the implemented lifetime and remaining
receiving-app/signed acceptance.


## Native conflict-list layout and targeting — October 15, 2026

The lower Conflict Files list now shares Commit/Working Tree's native header
menu, Fitting command, saved visibility/order/widths and confirmed Reset Columns.
RebaseDlg.cpp::m_FileListCtrl.Init supplies an explicit allowed-column mask: Path,
Extension, Status, Lines added and Lines removed. The native list honors that
mask; Path stays visible and unrelated shared-list columns cannot be enabled.
Preferences use the workbench's existing private/injectable settings store under
Rebase.ConflictFileColumns, shared by Rebase and Cherry Pick.

Column headers sort rows with native selection bound to stable Git path IDs.
Line counts use numeric comparison and unavailable values retain the shared
source ordering. The selected sort column/direction survive reopening. Changing
layout or order does not change checked commit paths. Scoped Copy and Space map
AppKit indexes through the current displayed order; the shared interaction also
supplies its native Home/End, focus, selection and header-copy behavior.

A popup captures its displayed row order and visible-column order alongside the
existing replay identity/stages/statistics. Copy All uses those captured columns,
and individual column copy uses the same displayed values. This preserves literal
Unicode/newline paths and the existing Conflicted status wording.

Reset keeps the owning repository lease and Quit count while its question is
pending. No retains layout; Yes restores the five source defaults. An owner
retired during the question cannot save settings or invoke its acceptance
callback. Closed/busy models reject layout/sort/visibility changes. The shared
header integration detaches on closure.

Source review also confirmed that author/date overrides belong to the existing
full Commit dialog used by replay's Edit/Squash split loop, including the first
squash author's date policy. This batch adds no extra replay author controls.

See [batch evidence](qa/replay-file-list-2026-10-15.json) for the actual validation
scope. Physical header gestures, full keyboard/VoiceOver, source menus still
listed above, signed sandbox execution and complete replay parity remain open.


## Revert and index-flag action family — October 15, 2026

The conflict-file menu now includes source-gated Revert, Skip worktree, Assume
Unchanged and Clear both flags. The immutable popup captures the selection mark,
selected paths and current flags alongside replay identity, HEAD, stages and
refresh generation. An eligible mark supplies upstream mixed-selection behavior;
Core independently checks each selected stage-zero entry and reports unavailable
entries after applying eligible ones. The owned refresh preserves that partial
failure and reports the actual resulting flags.

Index-flag questions use the source No default. Fresh replay/row/flag checks run
after the answer and before the locked-index operation. Reads convert the
existing Finder helper's absolute-path flag map into replay-relative row keys.
The Status cell, status sorting and clipboard use the captured flag wording.
Snapshot reads do not alter index flags, unmerged stages or working files.

Revert uses the existing native progress owner as a sheet. It asks for source
modified-file confirmation, restores against destination HEAD, retains added
working files and existing Trash recovery, and automatically closes successful
results without submodule choices. Retry refreshes selected-path status and
revalidates the same stopped replay/HEAD before each attempt; it does not require
the original status rows to survive a partial Revert. Submodule follow-up uses
the existing comparison route. Revert does not Continue, Skip or commit replay.

The Rebase parent retains its repository lease and busy/Quit accounting through
the question and child settlement. Its preparation Cancel routes to the Revert
child. Forced parent closure retires the child and cancels owned work. Both flag
and Revert operations queue an actual replay/view refresh after completion or
partial failure. Unpresentable/retired replay questions return refusal; their
default button is explicitly installed on the native window.

[Batch evidence](qa/replay-file-actions-2026-10-15.json) records the Core and native
checks, repairs and actual scope. Physical menu/cancellation/retry gestures,
broader submodule/type-transition failure variants, signed sandbox deployment and
the remaining menu families listed above remain open.
