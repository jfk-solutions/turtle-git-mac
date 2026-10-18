# Editing future replay actions — October 18, 2026

This connected family follows `GitLogListAction.cpp::SetSelectedRebaseAction`,
`ShiftSelectedRebaseAction`, `RebaseDlg.cpp::SetControlEnable` and the shared
`GitLogListBase.cpp` action menus at pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d` (`src/Resources/TortoiseProcENG.rc` /
`IDD_REBASE`). Windows reads actions from its in-memory replay list. The native
Git sequencer needs a durable checked edit of its pending todo and metadata.

## Native interaction

At a stopped Edit, conflict or Squash message, pending occurrences now accept
Pick, Edit, Squash and Skip through the existing native menu and action keys.
Space cycles each selected future occurrence independently in one publication.
Current/completed rows stay unchanged. The oldest occurrence and ordinary merge
Squash exclusions retain their existing source rules. Bulk buttons, reference
editing, ordering and drag stay in the choosing phase. A new mainline question is
required when restoring a skipped Cherry Pick merge without a captured mainline;
its selected parent is saved with that exact occurrence. Attribution and the
original merge identity survive use of a synthetic single-parent execution object.

The window retains the original repository, permission lease and preferences.
Saving actions preserves the current message draft, conflict checks, HEAD,
index and worktree. Duplicate requests, Continue, close and Quit are blocked
while the read/write is owned. Cancellation can stop preparation; publication
has no cancellation point between its metadata writes and todo commit. A late
Cancel after publication displays the actual saved result. Retirement fences
UI callbacks while keeping the owned read/write count until the operation drains.

## Saved session

A snapshot captures the stopped state, HEAD, occurrence order and exact todo,
done, identity, message-editor and Cherry Pick mapping bytes. Publication requires
these to remain unchanged. Unknown/custom/external todo commands or a plan that
cannot reproduce its captured commands are refused without discarding them.
The existing Git todo lock prevents competing writers. Pending action changes
update both Git's commands and the original occurrence metadata, so reopening
reads the saved values rather than a temporary native draft.

Structural sessions now use the native structural command generator from their
start, including all-Pick plans. The generator retains already executed commands
and rewrites only the future suffix, including merge Edit breaks, source parent
labels, Squash-group labels and deferred branch reference updates. An already
executed Edit is retained when a future Squash extends its group. Source-invalid
structural plans, including an unreplayed first merge parent, remain refused.
Older/custom Git-generated structural todos are not silently converted.

Message-editor metadata is created if the session gains its first Squash. It
retains captured author dates, messages, encoding and attribution while updating
future grouping actions. A journal stages the complete old/new metadata sets;
Git's todo replacement is the commit point. A later state/read/Continue restores
the original metadata if the old todo remains, or finishes the new side if the
new todo was published. Unexpected external bytes refuse recovery. As with other
Git lock files, a stale lock left by a terminated process must be resolved before
recovery; this is not a certified power-loss durability protocol.

## Evidence and remaining acceptance

[Core tests](../Tests/TurtleGitCoreTests/RebasePendingActionTests.swift) cover real
linear/structural replay, first-Squash message setup, repeated Cherry Pick
occurrences, restoring a skipped merge with mainline/attribution, reference
updates, stale/locked/cancelled input, both journal sides and unknown commands.
The hidden [native receiver](qa/rebase-pending-actions-native-2026-10-18.swift)
covers menu actions, durable reopen, current drafts and retired/cancelled ownership,
then actually continues the saved linear and structural replay. Retained revision
menus, bulk controls and structural row/recovery checks share the checkpoint.
Actual outcomes and failures: [batch evidence](qa/rebase-pending-actions-2026-10-18.json).

Remaining: physical mouse/keyboard/VoiceOver and all mixed selection combinations,
all external Git races and filesystem crash scenarios, older/custom structural
session conversion, full source enabled/omitted matrix, minimum macOS/Intel,
signed sandbox/Finder/App Store and complete Rebase visual parity. The remaining
shared Log commands in Rebase are tracked separately; the whole port is unfinished.
