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

This is a partial port of upstream's conflict tab. Squash conflict selection
and empty-result grouping, the Strip Commented Lines preference, all contextual
commands and full displayed layout/keyboard/accessibility acceptance remain
pending. Squash conflicts keep the existing staged Continue
path, and their checkboxes are disabled. The base
comparison is a native text sheet; it does not yet use the complete comparison
editor. No new screenshot establishes this tab's displayed layout.

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
