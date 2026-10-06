# Rebase Conflict Files

When Rebase or Cherry Pick stops while applying a commit, the lower file tab
becomes **Conflict Files**. It lists conflicted and clean tracked changes with
Path, Extension, Status, Lines added and Lines removed columns. Original
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

## Remaining parity work

This is a partial port of upstream's conflict tab. Checkbox-selected Continue,
partial-file preservation, editable conflict commit messages, all contextual
commands and full displayed layout/keyboard/accessibility acceptance remain
pending. Continue currently uses Git's existing staged resolution. The base
comparison is a native text sheet; it does not yet use the complete comparison
editor. No new screenshot establishes this tab's displayed layout.

## Verification

32 focused Rebase tests pass, including conflicted Edit, resolved-before-Continue
recovery, premature Split rejection and preservation of destination history.
The headless native receiver hosts the actual five-column table and drives the
real replay and quick Resolve models. It checks clean/conflicted rows, a path
containing Unicode and a newline, stage-1 comparison, single-path Edit routing,
replayed-side resolution, parent refresh, resolved-row retention/reopening and
final Continue. Editor handoffs and confirmation answers are injected; displayed
editors and user gestures are not established by this receiver.

Pinned upstream: `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseProc/RebaseDlg.cpp` (`UpdateCurrentStatus`, `REBASE_TAB_CONFLICT`
and conflict context-menu handling). Evidence:
[QA record](qa/rebase-conflict-files-2026-10-06.json).
