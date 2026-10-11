# Combine commits (implementation in progress)

TurtleGit implements the pinned TortoiseGit Combine workflow in Log and Sync.
Select a continuous range on the checked-out branch, then choose **Combine to one
commit**. The native Commit window combines the selected messages and forces
Amend. SquashDate chooses the oldest author date, newest author date or current
time. The dialog suppresses Commit & Push, ReCommit and post-actions for this
operation. If later commits sit above the selection, the workflow replays them
after the combined commit.

Cancelling the Commit dialog or a replay failure restores the original HEAD.
The working tree must be clean before preparation. The captured branch, HEAD and
ancestry are checked again before changing Git state. An active Commit is allowed
to finish before recovery begins after a forced owner close; Quit is blocked
until recovery ends. Sibling history/status views refresh only after replay or
recovery, rather than after the temporary amended commit.

Implementation: `HistoryCombineWindowController`, `HistoryCombineWindowModel`,
`CommitWindowModel.loadHistoryCombine`, and the `GitRepository` Combine methods.
The menu uses upstream `IDI_COMBINE` / `menucombine.ico`.

This page describes intended implemented behavior. The current continuation is
uncompiled and untested; do not treat it as an acceptance record. Full native,
Git-engine, recovery and signed sandbox verification remains outstanding.

Source: pinned `GitLogListBase.cpp` ID_COMBINE_COMMIT conditions and
`GitLogListAction.cpp` ID_COMBINE_COMMIT / CherryPickFrom, commit
`7338078f8ddd924b8cddee35f512f2286072136d`.
