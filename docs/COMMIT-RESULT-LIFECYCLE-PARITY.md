# Commit result recovery and the next draft

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.

## Complete the committed working state before the result

`CommitDlg.cpp:967` invokes `RestoreFiles` before client PostCommit at
lines 975–990. The source then prunes committed changelists before returning. Mark for restoration captures the original working bytes; the
user can temporarily reduce those bytes for a commit. A successful commit must
restore the captured full working file while HEAD/index retain the selected
committed contents. The client post-commit hook must observe that restored
working file. The existing native workflow previously delayed restoration until
after the result's post-action acknowledgement, so the hook observed the reduced
file instead.

The connected completion workflow keeps actual Git success separate from later
restoration, client-hook and changelist errors. A completion error must retain
its recovery state and report that Git already committed. It must not silently
retry Git or present a failed commit as though HEAD had not changed. Restoration
retains the captured repository/access and replaces only the explicitly marked
working paths. Source PostCommit runs only after successful Git; a rejected
pre-commit hook remains a failed attempt. Original index/working-copy semantics
and the existing failed-attempt Restore/Keep choice remain explicit.

Native restoration checks actual replacement errors and retains the remaining
copies; the source CopyFile loop does not inspect individual failures. Native
completion skips the client PostCommit hook when restoration failed and offers
no post-action handoff until recovery is addressed. Cancelling remaining
restoration/hook work cannot undo the Git commit that already succeeded. These
are explicit native recovery adaptations, not Windows failure-path equivalence.

Git itself can create a commit and still return nonzero afterward. An actual
post-commit hook replacing a checked file with a directory reproduced a Git
`mmap failed` error after HEAD changed. Native progress retains that command
failure, compares captured before/after HEAD and warns that a commit may already
exist. The warning asks the user to inspect Log before retrying; it does not
claim ownership or success from a HEAD change that could be concurrent. Failure
history and Restore/Keep choices retain their ordinary acknowledgement order.
A separate actual replacement error after Git returns successfully exercises
native completion recovery without conflating these phases.

## Retain attempted messages after failure

`CommitDlg.cpp:1068–1081` reloads and saves nonempty attempted messages and the
relevant non-Amend backup even after Git failure. The native failure path
previously skipped history persistence. Attempt state belongs to the captured
message, issue processing, normalization and repository preferences; it is not
reconstructed from a newer draft after a delayed result. A preflight warning or
branch cancellation before Git is attempted does not count as a failed commit.
Failed progress acknowledgement precedes publication to Recent messages. Closing
or cancelling an owner must reject late completion callbacks instead of saving
into a later window's history or updating its controls.

## Keep the visible draft separate from the attempt

The source uses `m_sLogMessage` for client PreCommit output, issue-ID insertion
and message-file formatting; those steps do not call the message control's
`SetText`. Native Commit previously published all three back to its visible
message. A real failed ReCommit with an issue ID failed the exact Undo check. Source
comparison also found this unregistered replacement of the visible draft; the
source keeps these buffers separate.

The editor now retains the raw user draft, with explicit editor commands such as
Add Signed-off-by retaining their visible behavior. Local attempt text carries
hook output, issue processing and formatting to Git/providers. Recent messages
store the prepared attempt separately. The existing formatter receiver now
asserts byte-exact raw editor text, byte-exact prepared history and exact Git
commit bytes, rather than conflating the buffers. Failed commits retain raw editor text and its Undo target while history preserves
the prepared attempt. The receiver waits for the actual native editor to become
editable after model/refresh completion before invoking Undo; an earlier
optimistic model-only wait consumed Undo while the editor was still disabled.

## ReCommit begins a new editor draft

The source installs the next template and explicitly calls `ClearUndoBuffer`
at `CommitDlg.cpp:1030`, before running the next Start Commit hook. ReCommit is a
new draft with a new Undo boundary. Refresh, appearance updates, normal history
selection and failed commits must not clear the user's current Undo stack.
The next draft reads its template once, excludes leftover operation messages and
retains the separate issue field, as the source does. The template passes through
the actual Start Commit hook before the new editor session is published. Failed
or obsolete preparation retains the previous draft and Undo until a new snapshot
is accepted. A dedicated editor Undo manager keeps unrelated input-field Undo
separate. The connected editor session distinguishes the next draft from an ordinary
programmatic message update, including a next template identical to the old
text. Subsequent native edits remain normally undoable. Late updates from a
retired editor cannot reset a replacement editor's session.

Resetting Amend/author/date controls is part of installing that draft. Delayed
SwiftUI checkbox callbacks must not reinstall the previous Amend/ordinary message
or override the new template/Start-hook result. A later deliberate user toggle
retains its ordinary metadata behavior. ReCommit restores the normal file list,
selection and commit-specific controls, while the captured repository and saved
completion-button preference keep their existing semantics.

## Checkpoint and remaining work

The Debug app build and ten native case/engine checks passed across Apple and
bundled Git through the grouped checkpoint and focused repairs. Core code was
unchanged and its suites were not repeated. Actual private Git commits, client
hook scripts, exact raw/history/commit bytes, Amend→ReCommit sessions, unrelated
window Undo and manual restoration were checked. Held hook configuration and
restoration scheduling exercise late cancellation/drain boundaries without
claiming every live hung child process. Both Git engines reproduced the actual
nonzero exit after a new HEAD and the separate native replacement error.
All fifteen owned receivers, including failed attempts, were reaped and
independently absent.

[Recorded evidence](qa/commit-result-lifecycle-2026-10-20.json) retains the initial
actor compile failure, actual Git partial-failure discovery, template-LF fixture
correction, raw-buffer source correction and native view-settlement repair.
Passing pre-repair unaffected cases were retained; only affected and previously
unstarted checks ran afterward. The build has existing compiler/toolchain
warnings. No new visual layout or screenshots are claimed for this behavioral
batch. A complete current hosted CI pass was not established.

Physical keyboard/IME/VoiceOver, every external hook/plugin, live signed sandbox
and installed Finder/App Store acceptance remain open. This family does not
certify the entire Commit dialog or application port.
