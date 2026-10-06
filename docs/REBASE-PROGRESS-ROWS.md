# Rebase replay rows

Upstream keeps its full commit list during replay: completed/skipped rows use gray
text, the current row is bold, Edit has a yellow background and Squash a gray
background. The comparison uses `RebaseDlg.cpp` and `GitLogListBase.cpp` at
`7338078f8ddd924b8cddee35f512f2286072136d`.

TurtleGit now retains the full list for its custom Rebase and Cherry Pick sessions.
The list remains newest first while IDs keep their original replay positions.
Completed rows remain available for Log inspection and clipboard commands.
Completed/Skip text is dimmed, the current row is bold, and Edit/Squash cells
have translucent yellow/gray backgrounds that adapt to macOS light/dark mode.
Accessibility values expose Pending, Current and Completed.

The replay identity file now records the selected action and merge mainline,
alongside original source hash and occurrence number. It survives reopening an
active session and keeps repeated Add rows distinct. Earlier identity files with
only hashes/occurrences recover actions from Git's completed and pending commands.
Recorded manual Skip steps are shown as Skip. Source hashes remain source hashes;
completed rows do not pretend to identify the rewritten output commits.

After a successful native Continue, the open dialog retains all rows as completed.
Abort retains the attempted list without marking unprocessed rows as completed.
Git deletes active recovery metadata when a session ends, so reopening a finished
session as a persistent history report remains unimplemented. If an external
process ends a session, Refresh reports that the session ended without inventing
whether the process completed or aborted it.

## Verification and limits

Core tests check full repeated-occurrence recovery at the second Edit pause,
legacy metadata without action fields and both merge-mainline recovery cases.
The native menu receiver checks Pick/Skip/Edit rows, progress, reopening, ordering,
numbering, completed-row clipboard inspection and the retained finished list.
It hosts the actual view without displaying windows; screenshots, focus,
accessibility interaction and selected-row contrast still require displayed QA.

Full progress recovery relies on TurtleGit's custom replay metadata. External
sessions without that metadata and structural Preserve Merges currently retain
the earlier pending-row recovery behavior. Advanced Log commands and further
post-operation controls also remain incomplete.
