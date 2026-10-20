# Older and external paused Rebase sessions — October 20, 2026

This family extends the [durable pending-action workflow](REBASE-PENDING-ACTIONS-PARITY.md)
to recognized sessions created by older TurtleGit versions or another Git client.
The source comparison is pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`, especially
`GitLogListAction.cpp::SetSelectedRebaseAction` and `GitLogListBase.cpp`'s Rebase
menus. Current/completed occurrences remain protected; the oldest occurrence and
ordinary merge cannot gain source-invalid Squash. Windows retains its replay list
in memory; the native macOS integration must preserve Git's durable sequencer.

## Connected native workflow

Open the existing Rebase window at a stopped Edit, conflict or Squash message.
Its ordinary Pick/Edit/Squash/Skip menus and keys save future action changes for
recognized older/external sessions. There is no separate adoption approval or
restart. Reading the action-edit snapshot does not create native metadata; the
explicit action change publishes the supported conversion and requested edit
through the same checked operation. While owned, the native status reports
“Saving replay actions…” and Continue, conflicting actions, close and Quit retain
the existing preparation/worker guards.

The window keeps its original repository, access, preferences and current message
draft. Completed commands, HEAD, index and worktree are preserved while editing
future actions. Reopening reads stable occurrence identities and saved actions. Completed Current Skip
bookkeeping also remains visible after another future-action save and reopening.
Cancellation can stop preparation; publication has one todo commit point and
retains the actual saved result if cancellation arrives afterward. A retired owner
cannot publish a late UI result or release its worker/access early.

## Captured Git plan

Recognized Git-generated linear and structural sessions are projected from done
and todo, including original merge objects, repeated occurrences and completed
rows. The projection used before adoption also drives saved sessions, retaining
the stopped occurrence and message identity. Older identity records without
optional action fields recover those actions from Git's commands.

The accepted structural skeleton preserves Git's existing labels, resets, merge
commands and branch-reference update commands. Future changes do not regenerate
the completed prefix using a different native label scheme. An adopted plan
sidecar records that original skeleton alongside occurrence/message metadata.
Unknown, custom or unreproducible commands are refused with their todo bytes
retained. Arbitrary `exec`, `fixup`, `reword` and new-root command conversion is outside
this family. Adopted structural Squash requires a contiguous preceding linear
action; crossing a label/reset/update-ref/break/merge boundary is explicitly
refused. A native structural or Cherry Pick session with its entire original
identity archive missing is refused because its original topology/attribution
cannot be reconstructed from commands alone. An intact older archive whose
optional action fields are absent is supported through its captured message
configuration or matching command actions.

Publication checks the captured session, HEAD and exact command/metadata bytes,
then uses Git's todo lock. Journal recovery rolls back staged metadata if the old
todo remains or completes the new metadata if the new todo was published.
Unexpected external bytes refuse recovery. Existing older journal formats remain
part of the compatibility boundary. This is a recoverable checked transaction,
not a claim of certified filesystem/power-loss durability or serialization with
all other Git clients.

## Validation and remaining acceptance

[Core tests](../Tests/TurtleGitCoreTests/RebaseSessionAdoptionTests.swift) and the
[hidden native fixture](qa/rebase-adoption-native-2026-10-20.swift) use actual Git
sessions rather than assuming a window exists. [Batch evidence](qa/rebase-session-adoption-family-2026-10-20.json)
records executed checks, repairs, owned cleanup and accepted/refused cases.
Physical keyboard/VoiceOver and visual acceptance, minimum macOS/Intel, installed
signed sandbox operation, all external races, arbitrary custom todo conversion
and complete upstream/App Store acceptance remain unproven. The whole port is
unfinished.
