# Replay recovery file report

This connected family compares the native Rebase/Cherry Pick recovery report
with TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`. It is a partial
workflow audit, not whole-application certification or a physical acceptance pass.

## Source contract

`RebaseDlg.cpp:243` initializes the shared GitStatusListCtrl with Path, Extension,
Status, Lines added and Lines removed, excluding Commit/Restore/Changelists menus.
Recovery enables checkboxes and reads working status at `2454–2469`; historical
selection sets the exact current commit at `2942–2944`, while recovery clears that
revision at `1334–1335`. RebaseDlg does not assign the two-revision operands or an
amend flag to that control. The final `true` Init argument means working-copy
access. Conflict orientation comes from the actual repository's IsRebaseActive
in `GitStatusListCtrl.cpp:387`, not from the dialog title.

`GitStatusListCtrl.cpp:3618–3655` takes the complete displayed selection, asks one
multiple-diff question, then opens ConflictEdit for every unmerged row and the
ordinary/current-file comparison for other eligible rows. Missing added/renamed/
copied rows are skipped by that primary action; ordinary deleted/missing rows can
still compare. Double-click at `2926–2973` uses the pointed row and excludes its
checkbox state icon. The explicit Compare command at `2234–2247` instead calls
StartDiff for every selected row, including conflicts; StartDiff at `3026` uses
the current applied HEAD when the working-version sentinel is empty. It does not
substitute index stage 1 or ConflictEdit for that explicit menu command.

## Native report and connected commands

Recovery now uses the same actual AppKit report as other conflict/status lists.
It preserves the five allowed columns, saved order/width/visibility, numeric
sorting, text font, row colors/icons, highlights, independent checked files,
working drag receipts and position refresh. Changing check availability updates
the existing native buttons without replacing the table header. Read-only checks
stay disabled while row inspection remains available. Return/keypad Enter and
the window's default Continue action have separate ownership; pointer activation
uses one actual row. Shift-F10 and accessibility Show Menu retain the selection.
Copy, Space, Delete, context and Return routes require their appropriate native
event/window/focus/visibility admission rather than borrowing a text editor's key.

The native menu retains existing Add variants, explicit Compare/Unified Diff,
conflict Edit/Resolve, log/old-name/submodule/blame, Revert/index flags, export,
editor/Open/Open With/Reveal, local/imported comparison marks, Delete, Ignore and
clipboard operations. The source default Edit Conflict or Compare item is bold;
all action groups retain source artwork. Copy includes Extensions and visible
column order. One captured receipt is consumed once and cannot target a later
selection, sort, layout, mark or replay session.

Typed primary plans retain all selected raw statuses in report order, actual
conflict-stage records, repository/backend, source window/access, tools, settings,
Shift choice and actual rebase orientation. Mixed conflict/ordinary selection
does not disappear through a singleton-only callback. Primary missing-row and
retained-copy intents remain distinct; explicit Compare is a separate owned mode.
Fresh stages/orientation are checked before a conflict editor or ordinary conflict
comparison is prepared. The existing native Squash/amend-to-parent comparison
policy remains an explicit replay adaptation; this work does not silently change
its grouped commit base.

Quick Resolve is an owned native confirmation/progress sheet. Its accepted stage,
replay-session, selected-row, backend and settings receipts are checked before
mutation. Submodule Reset successors belong to that same chain. Cancel or source
retirement closes owned children and cancels reads; source/global worker counts
and onClosed survive until actual work and both original sheet-parent links drain.
Actual resolution refreshes through the originating refresh-after-resolving
preference after the child chain closes. It does not continue or commit the replay.

The source path here is Rebase and the application's Cherry Pick replay. Revert
commits has a separate implementation and is not advertised as another mode of
RebaseWindow. Independent comparison/editor windows retain their existing launch
lifetime; an awaited launch is not a promise that a user has finished editing.

## Verification scope and remaining work

`docs/qa/replay-recovery-primary-native-2026-11-23.swift` exposes
`ReplayRecoveryPrimaryVerification.verify(base:git:)` to the grouped private
native receiver. It prepares actual paused Rebase and Cherry Pick sessions and
checks native mixed Return/click/check behavior, stage/backend/settings capture,
one warning, explicit conflict comparison, fresh-stage replacement refusal,
actual owned Resolve, refresh and forced Close/Quit/column-reset drainage. Windows
are invisible/offscreen; repositories, preferences and pasteboards are private.
Injected child presentation avoids launching external applications.

The primary recovery receiver passed with system and bundled Git, including
actual paused Rebase and Cherry Pick sessions and strict index preservation.
The shared Resolve close path hides its finished window after awaited child and
worker drainage, before releasing caller ownership. Native child receipts and
visibility assertions cover the previously exposed detached-window defect.

The retained replay-menu receiver is adapted to inspect the actual native report
and header rather than removed SwiftUI probe mirrors; its behavior assertions are
preserved. Execution results, prior failed attempts and focused repairs belong
in the grouped [checkpoint record](qa/replay-blame-family-2026-11-23.json).
A scoped receiver pass does not establish physical or full replay acceptance.

Remaining scope includes physical pointer/keyboard/VoiceOver and full visual
comparison, exceptional nested submodule and replay-phase combinations, external
tool and signed access acceptance, and a complete hosted run for the final source.
The dialog ledger's mapped controls remain partial reviews, not feature completion
percentages. The excluded Windows/test/dormant resource entries do not themselves
establish additional missing end-user dialogs.

## Shared report geometry found during screenshot review

The coordinated capture exposed default-width collapse in Resolve/Sync: automatic
AppKit column resizing ran while their report still had a zero-width construction
frame. The shared report now disables that resizing before adding columns, keeps
its real defaults/saved widths and lets the horizontal scroller handle overflow.
The checkbox header has no inherited generic “Field” caption. Position restoration
waits for a real viewport layout and constrains its saved point to the actual
AppKit document bounds; source teardown still acknowledges a pending restoration.
Log's separate changed-file report receives a nonzero native header height, so
its column captions occupy actual visible geometry. The six affected original
captures are retained as rejected evidence. Their corrected-build replacements
were captured and accepted for the documentation; the capture receipt distinguishes
those replacements from the six retained images. This bounded review does not
claim that every upstream dialog has visual parity. Native workflow results are
recorded separately in the grouped checkpoint.
