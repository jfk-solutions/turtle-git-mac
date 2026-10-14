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

Earlier implementation had deferred validation. The connected October 14 batch
below records its current scope; full physical and signed acceptance remains open.

Source: pinned `GitLogListBase.cpp` ID_COMBINE_COMMIT conditions and
`GitLogListAction.cpp` ID_COMBINE_COMMIT / CherryPickFrom, commit
`7338078f8ddd924b8cddee35f512f2286072136d`.


## Connected selected-history workflow batch — October 14, 2026

Log and Sync now validate every captured Combine row against HEAD ancestry before
showing the command, rather than accepting matching endpoints around a mismatched
interior row. Menu checks allow dirty trees as upstream does; preparation still
refuses them. Both owners register and cancel their read tokens on retirement,
retain repository grants and keep Quit blocked until the read settles. Menu close
cancels its request; changed selections and retired owners refuse late enablement.
The preparation API reuses this full selection validation.

Combine streams its hard/soft preparation resets, replay and independent rollback
through the bounded CR/UTF-8 parser and native colored output/copy-icon control.
Repository callbacks retain original result strings. The output limit applies to
presentation, not full Git result storage. Current work and percentage are shown
when emitted. Success reflects completion of amendment and replay, not the
intermediate Commit. Preparing and recovery retain scope and process ownership.
Cancel is disabled while Commit is presented or rollback is running; forced
closure still cancels normal execution and waits for an active Commit child before
restoring original HEAD. Rollback is independent of the cancelled command token.
No late output, completion or sibling refresh publishes from a retired owner.

Revert is implemented in the same batch; see [Log Revert](LOG-REVERT-PARITY.md).
Physical menu/display/Commit-button/keyboard, actual nested sheets and signed
sandbox/App Store acceptance remain open. Hidden preset checks and actual Git
amend/replay are not claims of native Commit button interaction or complete
history/application parity.


The Debug build, five affected Core tests and two native engine cases passed on
the first validation attempt. Core checks cover a real combined middle range with
replayed descendants, unchanged final tree/branch, mismatched interior-row refusal,
dirty preparation, cancelled hard/soft recovery and both merge Revert mainlines.
The native family covers preserved messages, Skip/Commit ordering, actual Commit
presets/Git amendment/replay, forced pending-child rollback and retired Log/Sync
reads. Both receivers were reaped. See [batch evidence](qa/history-workflows-2026-10-14.json).
No full Core or legacy Sync suite was repeated. Actual Commit-button and all
physical/nested-menu interactions remain outside this evidence.
