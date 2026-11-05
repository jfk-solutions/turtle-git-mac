# Exact-name operations, Retry and result retention

This continuation covers working-file Revert/Retry, Push remote selection and
the completed operation/error/log lifecycle. The
[batch checkpoint](qa/operation-identity-retry-2026-11-05.json) records 39 distinct
Core methods cumulatively and twelve native case/engine combinations, plus the
affected native Revert recheck against the rebuilt Core. It does not establish
signed, physical Finder or complete hosted acceptance.

## Source behavior and macOS adaptations

Pinned source is `7338078f8ddd924b8cddee35f512f2286072136d`.
`RevertProgressCommand.cpp:43–145` captures the target list and independent
ordinary/renamed-file recycle policies, then executes its unstage, deletion and
checkout cohorts with file notifications. The Mac implementation retains the
captured selection and recovery policy, protects index publication and exposes
Retry as an explicit native extension. A retry must not acquire a different
disposal policy or substitute a canonically equivalent Git name.

Git names use their original UTF-8 bytes even where Swift String equality treats
NFC and NFD spellings as equivalent. On macOS, Git's `core.precomposeunicode`
also preprocesses command arguments. Revert's scoped status and index queries
must disable that preprocessing for their existing Git names, preserve literal
pathspecs and validate complete NUL-framed output. The override belongs to the
operation, not persistent repository configuration or a global change to new-file
filesystem scanning. Explicitly selected ignored rename counterparts remain
distinct from implicit rename counterparts; a stale name fails closed.

Native result rows and copied/logged output retain the same selected identity.
A clean selected index entry remains eligible for Retry after a prior attempt
already restored it. Its canonical index peer and HEAD remain unchanged. These
checks do not claim that APFS can materialize two canonically equivalent working
filenames as separate files.

A disposable macOS diagnostic confirms that a scoped raw Git query can report
an NFD unknown name while an NFC index entry addresses the same device/inode.
That is valid Git output, not permission to dispose an unselected tracked
working file. Unversioned projections therefore require physical/index ownership
validation before Retry publication or file disposal. Ordinary nonalias mixed
unknown/ignored selections retain their existing Git-error and recovery policy.

`PushDlg.cpp` remote refresh/default selection and F5 handling provide the source
reference for the Push chooser. Two AppKit actions can arrive before SwiftUI
updates the representable. A remote action advances its own accepted form
receipt after a successful choice, while exact catalog, source, refresh, child,
Quit, cancellation and retirement ownership remain authoritative. This preserves
rapid NFC/NFD choices and the user's manual remote choice across a successful
catalog refresh, with source-style fallback when that exact remote disappears.

## Completion and action log

A Git command's completion receipt and its later producer/inspection result have
separate ownership. Stash retains its accepted native completion footer. Missing
error detail must still be appended within the captured output limit when a
silent producer throws after a failed receipt. A successful command followed by
an inspection error keeps that accepted success receipt and reports the
inspection error once; it must not invent follow-up actions or hide pending work.

Retry saves the complete previous result before clearing the display. Close
appends at most one complete result for the current attempt. Multiline native
footers are part of the stored snapshot, so validation compares ordered complete
attempts rather than expecting an entire result to be a single logfile line.
Quiet Git success still has a native completion footer even when raw output is
empty. Duplicate saves, disabled logging and logging failures retain their
existing independent behavior.

## Checkpoint scope

The hosted source `57cd45de` failures are retained in
[the CI record](qa/hosted-ci-57cd45de-2026-11-05.json). Native coverage
includes actual canonical-peer index restoration followed by failed-result/clean
Retry, original bytes and HEAD, exact result/clipboard text, close deduplication,
retired workers, rapid native remote choices and delayed catalog replies, and
command/inspection error plus action-log ownership. Checks use private
repositories, homes, preferences, logs and pasteboards and invisible/offscreen
windows. The first checkpoint retains its four Core failures and a
transport-wrapper gate timeout. Repairs distinguish typed cancellation and empty
Git templates from the real filesystem projection issue; the transport fixture
selects its CLI backend in both the repository and the dialog's private
preferences, retaining its original cancellation/Quit assertions. Only affected
checks were repeated. These passes do not prove the remaining hosted lanes or
every upstream dialog complete.
