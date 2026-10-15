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

This is a partial port of upstream's conflict tab. Full displayed Squash checkbox acceptance and all contextual
commands and full displayed layout/keyboard/accessibility acceptance remain
pending. Squash conflicts keep the staged Continue
path with active checkboxes; see [Squash message and checkbox behavior](REBASE-SQUASH-CONFLICTS.md). Single ordinary base comparison now
uses the full native editor; multiple selected paths use the shared working-file
comparison preparation. The separate unified command retains an aggregate patch. No new screenshot establishes this tab's displayed layout.

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
The remaining source status-list behavior (including broader
gitlink prepared-comparison combinations), drag/drop, all conditional layouts, physical keyboard/VoiceOver,
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


## File comparison and child history family — October 15, 2026

The lower file list now exposes source-gated Show changes as unified diff, Mark
for comparison, Compare with the captured mark and Show log of submodule, with
the existing original command artwork. Ordinary Compare with base is available
for clean tracked rows. Mixed/multiple selection forwards every selected path
instead of dropping ordinary rows when conflicts are present. A single ordinary
conflict with stage 1 keeps the existing editable Base/current comparison.
Working comparisons carry the captured Squash parent-base choice.

Unified preparation follows IDGITLC_GNUDIFF1: each captured row contributes its
Git patch in displayed order to one raw-byte aggregate. Rename inputs include the
old path; Git's configured context and native rename/copy detection remain in the
command. Fresh stopped-replay/HEAD/row/flag checks run before preparation and
before handing off. One immutable read-only unified viewer opens, with no refresh
or Apply, through the configured external/built-in tool choice. Built-in viewers
are owned by the replay controller, block parent close during their busy/sheet
work and close on owner retirement.

Local marks refer to working content, as in the source status list. A popup
captures its mark and target independently of later highlighting or a replacement
mark. Rebase/Cherry Pick also import an authorized Finder mark on open and when
publication changes, retaining its grant through the shared comparison route.
Repeated publication of the same mark does not override a subsequent local mark.
File marks use the existing comparison factories; deleted paths and gitlinks
remain excluded from the native regular-file mark command. Gitlink mark/directory
comparison parity remains open.

Submodule Log retains the superproject Log command and adds the initialized
working-child route. The shared resolver validates a real child checkout and
refuses parent-repository discovery from uninitialized or unrelated directories.
Its owned token, grant and Quit accounting settle before delivery; retirement
cancels it. No clone or network access is performed by this read.

The initiating Shift choice now spans the entire captured file-action operation,
including working pairs and Base viewers created after a Git read. Explicit
marked/unified choices survive the same suspension. Stale-generation or retired
preparations cannot create viewers or dispatch a captured comparison.

[Grouped evidence](qa/replay-comparison-family-2026-10-15.json) records actual
patch bytes, selected-path preparation, captured marks, initialized gitlink
history, native child ownership and retirement. Shared working/staging statistics
now read raw Git modes so added, changed and deleted gitlinks retain their
submodule classification. Physical
menu/tool activation, Finder/security-scope grants, full gitlink comparisons,
remaining mutation menus and complete replay/application parity remain open.


## Add, Ignore and Delete — October 15, 2026

The replay file tab now offers source-gated Add, Ignore and Delete actions with
original command icons. The source replay filter still excludes standalone
untracked/ignored rows. A versioned deletion with a local unversioned copy can
be re-added; Shift exposes executable/symlink Add only for a non-directory mark.
Add uses the native progress sheet and existing transactional index preparation.
The replay progress sheet suppresses the Commit post-action, as upstream's
replay menu mask does. Mode post-actions retain the same replay identity and HEAD.

Ignore uses the existing native Ignore Type and Ignore File dialog as an owned
sheet, including literal-name/extension/containing-folder menu choices. The
selected popup and replay state are validated again when Apply starts, before
writing rules, and before any later removal phase. Changes while the options
sheet is open refuse the stale request. Closing or cancelling retires owned work.

Delete uses the marked row's missing/unversioned eligibility and captured full
selection. The native question defaults to No; Shift requests permanent deletion.
After Yes, fresh replay/HEAD/row/index-flag validation runs before the shared
working-file backend. Normal deletion uses macOS Trash and reports recoverable
paths; failure never falls back to permanent deletion. Missing selected files
remove only their exact index entries. Partial failures retain backend recovery
information. Parent refresh and repository change publication occur after the
owned operation/dialog settles, including failures, without advancing replay.
Keyboard Delete uses the same captured selection mark and confirmation route.

Owned Add and Ignore sheets keep the parent busy and its access lease alive.
Parent cancellation routes to the active child; forced closure cancels/retires
it and releases the waiting parent operation. A late Add validation reply cannot
stage files or publish completion. These changes reuse existing Core mutation operations. The shared Ignore
ownership check now compares canonical repository paths, so a valid root with
a different URL directory hint is accepted while nested/outside repositories
remain rejected.

[Grouped evidence](qa/replay-mutation-menus-2026-10-15.json) records actual Add
modes, Ignore rule writes/refusals, Delete refusal/stale replies/index effects,
recoverable Trash bytes and unrelated unmerged-stage/HEAD preservation. Full
physical input, signed Finder/App Store acceptance and complete replay parity
remain open.
