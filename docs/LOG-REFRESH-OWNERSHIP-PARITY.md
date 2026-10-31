# Log refresh and unified comparison ownership

The pinned source is `7338078f8ddd924b8cddee35f512f2286072136d`.
`src/TortoiseProc/LogDlg.cpp:1250–1269` routes the Refresh button through the
history list and restores the displayed message/ref controls. Its operation
completion refresh at `3071–3077` refreshes without clearing the filter. The
selection handler's background-thread guard is commented out at `1869` onward;
a continuing walk does not prohibit inspecting already displayed revision data.
The existing [streamed file navigation audit](LOG-STREAMED-FILE-NAVIGATION-PARITY.md)
records the related captured revision/file command contract.

## Native workflow family

Repository notifications coalesce while a captured comparison, history load,
file-navigation owner or reference picker is active. A manual Refresh blocked by
one of those owners now retains the same pending intent. The intent is consumed
only by an admitted reload; settling an owned unified comparison cannot report
idle while history, file navigation, another unified session or followed-file
comparison is still active. Selection changes cancel captured comparisons rather
than sending their result to a new selection. A same-selection detail/history
settlement does not invalidate an already captured whole-revision/working-tree
unified comparison merely by incrementing its detail-generation counter.

Revision/working-tree, selected-file and change-set unified actions share session
settlement and captured Shift choice. Each session checks its original generation,
selection and, where relevant, file/projection identity. Close cancels the owned
unified sessions and waits for their actual worker drain before retrying the
native close. Forced teardown also retains the controller's completion lifetime
until those sessions drain. Existing global session accounting continues to gate
Quit; no duplicate global worker counter was added. Invalidation fences callbacks
before publishing cancellation/idle and clears pending refresh. Reopening requires
a fresh model; a retired model's reload remains refused.

## Retained failure and validation boundary

Old hosted run `41129980751`, distribution job `124326670601`, step426,
“Native Cherry Pick and Rebase recovery across Git versions,” failed with system
Git at `cherry-pick-native-receiver-2026-10-06.swift:1856`. This is the shared
30-second `until` assertion inside `verifyNativeLogDeferredRefresh`, not evidence
of a particular Cherry Pick/Rebase Git operation failing. The unlabelled timeout
did not identify its call site. The old fixture also attempted to reload an
invalidated model before its final held-comparison cohort, which production
correctly refuses; the repaired fixture uses a fresh model and separately
asserts the old owner stays retired. The old runner inherited HOME/preferences
and used a separate complete source compilation; focused current checks use
private preferences, named wait diagnostics and cached native receiver ownership.

The [grouped validation record](qa/log-refresh-ownership-2026-10-31.json)
records a passing Debug build and the focused three-helper native group against
system and bundled Git. The initial native fixture compile failed because its
linked module could not access a fileprivate generation counter; no receiver ran.
A fixture-only busy-admission observer retained the one-refresh assertions without
changing product visibility, and both engine executions then passed and were
reaped. Real parent-working comparisons, grouped merge files/Revert, unified
viewer routing and deferred refresh assertions remain intact.

Current coverage includes real Git history/working-tree bytes, busy/idle/manual
and reference-picker coalescing, captured selection cancellation, overlapping
history/comparison ownership, actual offscreen native Close/drain, permanently
retired refusal and fresh reopen. Held handoffs/projection gates distinguish
cancellation from worker drain. Followed-comparison/file-navigation overlap is
repaired by shared ownership terms but is not separately exercised by an
artificial fixture seam. No Core implementation changed or Core suite repeated.

These Debug checks do not certify physical focus, every upstream Log option,
signed deployment or a complete hosted CI pass. Installed build43 predates this
Log repair. No product layout or native label changes are part of this batch.
