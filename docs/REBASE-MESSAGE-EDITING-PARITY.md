# Rebase and advanced Cherry Pick message editing

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This connected family covers stopped message editing and the checked amendment
handoff in `IDD_REBASE` / `IDD_REBASECHERRYPICK`; it does not complete either
resource or the complete port.

## Source behavior and native implementation

- `src/TortoiseProc/RebaseDlg.cpp:1488–1544` permits an edited conflict message
  before entering the stopped Edit phase. Existing native checked-conflict
  commits, conflict hint approval, message cleanup and source authorship remain
  in use; this batch does not replace that engine or its empty-result choices.
- `RebaseDlg.cpp:1565–1611` sends dirty Edit through `CCommitDlg` with the whole
  project, file checkboxes, the current message, Amend and Amend-diff-to-last
  semantics. Ordinary amendment repeats while tracked changes remain; explicit
  Split instead creates replacement parts. Native Continue now prepares that
  same distinction. `GitRepository.beginRebaseEditSelection(expected:expectedHead:)`
  validates the complete stopped state and HEAD, returns nil for a clean worktree,
  or writes a durable `RebaseSplitState` in amendment mode (`conflictRecovery`,
  zero accepted parts). It never resets HEAD or silently commits the whole index.
- `src/Git/Git.cpp:2618–2654` defines clean worktree using tracked worktree/index
  differences and ignores submodules; untracked/ignored files do not open the
  Commit dialog. The native preparation and repeated selection loop use these
  same working-tree/index diff gates with `--ignore-submodules`.
- Existing `CommitWindowModel.loadReplaySplit` supplies the source file selection,
  message, author/date controls, empty-result approval and commit backend. The
  first accepted selection amends the applied commit with its parent topology;
  later selections repeat amendment while preserving excluded index/worktree
  changes. Explicit Split remains a separate mode. Cancelling the first dialog
  removes only its unstarted durable handoff; reopened zero-part handoffs resume
  the same amend dialog. A now-clean zero-part handoff retires before Continue.
  Accepted author/date choices use the existing Commit options and backend.
- `RebaseDlg.cpp:2520–2573` installs conflict/Edit/Squash messages, uses applied
  HEAD for Cherry Pick attribution and clears the undo buffer when the stopped
  editor changes. `RebaseSessionSnapshot.messageCommit` captures the actual applied
  HEAD together with the existing coherent stopped-state snapshot. Native Edit
  uses that message (including `cherry picked from`), presents its author/date,
  and resets editor identity on a phase/occurrence/applied-HEAD change. Same-phase
  refresh keeps the draft and undo identity. Squash uses its existing combined
  message and date policy, rather than substituting the applied HEAD message.
- Source author/date checkboxes belong to the invoked Commit dialog; this batch
  does not invent competing Rebase checkboxes. The message editor refuses writes
  outside its existing editable phase/ownership gates. Stale form bindings cannot
  write a later occurrence. The existing source options, message preparation,
  conflict-hint approval and empty-result Commit/Skip/Cancel remain connected to
  their existing consumers.

As a macOS recovery adaptation, the inherited private/default preference domain
stores one draft under the repository's canonical path. Its Codable identity
includes original HEAD, branch, onto, stopped occurrence, step, applied HEAD and
phase, comparing Git names by UTF-8 identity. Same-phase reopening restores even
an empty draft. A changed HEAD or stopped occurrence rejects it; completing or
aborting clears it. User text is never used as a Git argument. The draft is not
an approval token: every continuation still validates actual replay state/HEAD.

The owned preparation has cancellation, access retention and preparation counters
through the actual return. A cancelled write is recovered as a durable handoff,
not reported as an applied commit. Commit sheets inherit the Rebase owner's
alpha before presentation; the existing Commit owner manages its progress,
message/author helpers and cleanup. Ordinary parent Close/Quit respects owned
preparation and child windows; forced retirement cancels work and closes children.

## Grouped validation

[`qa/rebase-message-edit-native-2026-10-18.swift`](qa/rebase-message-edit-native-2026-10-18.swift)
exports `RebaseMessageEditVerification.verify()` for the grouped receiver. It uses
private repository/preferences, hidden owned windows and the app's editor helper.
It exercises advanced Cherry Pick with attribution, author/date context, draft
refresh/reopen, actual checked Commit amend cancellation and acceptance, applied
parent/author/date preservation, next-Edit message/undo/binding retirement, empty
draft preservation and successful cleanup. Failure closes/drains owners and
aborts only the test-owned replay.

`RebaseMessageEditingTests` adds three Core cases: clean/untracked/cancelled
preparation; durable checked amendment with author/date options, excluded index
preservation and reopening; and unstarted cancellation plus stale-HEAD draft
identity. Existing snapshot, conflict-selection, Split and Squash coverage remains
applicable. Results belong to the parent's grouped operation-workflow checkpoint;
this implementation agent ran no builds or tests.

## Remaining boundaries

This is not a visual audit of every Rebase control. Source clean-worktree amend
failure Retry/Ignore presentation still uses the native owned error/retry path;
an Ignore-and-continue handoff is not added here. Windows-only taskbar and
Scintilla implementation details use existing macOS progress/editor controls.
Physical acceptance, signed deployment and complete hosted CI are not established
by this focused family fixture.
