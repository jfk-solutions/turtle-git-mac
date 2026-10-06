# Rebase completion actions

The pinned `Commands/RebaseCommand.cpp` configures Show Log and Restart Rebase.
`AppUtils.cpp::RebaseAfterFetch` configures Show Log, Push, Send Mail and Rebase.
`RebaseDlg.cpp` shows the split post-operation control only at Done. These sources
are at `7338078f8ddd924b8cddee35f512f2286072136d`.

TurtleGit now offers those command sets in a native split control at the left of
the completion row. The main button opens Show Log; its menu includes all choices
with original icons. Done remains the primary closing button. The original
`menusendmail.ico` is included unchanged with exact provenance and license notice.

The control requires a successful native Rebase completion. It is absent during
replay, after Abort, after an externally ended session of unknown outcome and in
Cherry Pick, where upstream does not configure these post buttons. Busy and
child-operation guards also apply.

Show Log, Push and Send Mail close Rebase and hand off to the existing native
workflow for the same repository/access lease. Push uses HEAD, the completed
branch's current source. Send Mail opens Format Patch with the upstream-to-branch
range and Send Mail after create enabled. macOS requires the user to choose an
output directory; export then opens the existing mail composer with attachments.
It does not automatically send a message. This differs from upstream's immediate
patch generation into the worktree before opening its mail workflow.

Restart Rebase reloads the normal chooser in the same native window, refreshing
references rather than replaying the old plan. Rebase after Fetch retains its
upstream, Preserve Merges and configured auto-start behavior, as upstream does.

## Verification and remaining work

The native receiver performs a real Rebase, then invokes the completion handler.
It checks direct/after-Fetch command sets, busy/unsuccessful/Cherry Pick guards,
Log/Push/mail range and closing callbacks, the actual mail-enabled Format Patch
controller, unchanged HEAD/index during handoffs and restart/reset behavior.
Original icons also pass the shared decode/pixel tests.

Handoffs and closing callbacks are injected; hosted views and the Format Patch
window are hidden. No email is sent. Displayed split-control positioning, focus,
accessibility and signed sandbox export/mail composition remain unverified.
Active sessions now persist versioned completion context in Git's state directory,
so reopening restores Fetch/Pull origin, auto-start, branch/upstream/onto choices,
Force and Preserve Merges. Legacy/malformed context falls back without preventing
recovery. Git removes the metadata when the session completes or aborts.
See [session recovery](REBASE-SESSION-CONTEXT.md).
Full application and Rebase parity are still incomplete.
