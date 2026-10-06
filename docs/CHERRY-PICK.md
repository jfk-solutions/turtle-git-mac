# Cherry Pick from Log

Open **Show Log**, select the commit or commits to copy to the current branch,
and choose **Cherry Pick this commit…** or **Cherry Pick selected commits…**.
The command opens a native Cherry Pick plan. Opening the plan does not apply any
changes. A selection whose first visible row is HEAD, a bare repository or an active
merge does not offer this operation. Stash commits can be selected, as upstream
permits.

The upper list preserves the selected Log order, newest first. Replay proceeds
from the oldest retained entry. Its numbered rows show the action, commit hash,
message, author and date. Select a row to inspect its changed files and message.
Use the row's context menu to choose **Pick**, **Skip**, **Edit** or **Squash**.
**Up** and **Down** change the replay order; **Pick ALL** and **Options** change
multiple rows. Up/Down also move multiple selected rows together; hold Shift to
move them to the top or bottom. With the list focused, P/S/Q/E choose actions,
Space cycles them, and U/D move rows (Shift+U/D moves to the ends). The first
retained entry cannot be Squash. **Add** opens a native Log picker that accepts multiple commits. They appear
above the existing list, default to Pick and replay after the existing entries.
Cancel leaves the plan unchanged. You can add the same commit again; repeated
rows remain separately selectable after an interruption. An already-applied patch
may stop as empty and require recovery.

Enable **add "cherry picked from"** to append the original selected commit ID to
the copied commit's message, like Git's `-x` option. This preference is remembered.
Branch, Upstream and Onto are disabled because the destination is the current
HEAD; Force Rebase and Preserve Merges are hidden in Cherry Pick mode.

Choose **Continue** to begin, matching TortoiseGit’s Cherry Pick dialog. For each retained merge commit, TurtleGit
asks which parent determines its patch. Parent buttons include the parent subject
and abbreviated hash. Canceling a parent prompt stops preparation without changing
HEAD. Before replay starts, **Abort** closes the plan. These prompts occur before replay begins; upstream asks as it reaches each
merge commit.

An **Edit** action stops after applying the commit. You can adjust and stage files
in **Open Working Tree**, change the message and choose **Amend**, then **Continue**.
For conflicts, resolve and stage the files in Working Tree, refresh the state and
continue. **Skip** discards the current commit and its resolution edits; **Abort**
restores the destination branch and HEAD captured when the plan started. Dirty
working trees are rejected by the replay backend; automatic stash/restore is still
pending.

Interrupted operations retain Git's replay state. Opening Rebase or Cherry Pick
again recovers the operation in Cherry Pick mode, with the original selected
commit IDs, remaining actions and recovery controls. Closing its window leaves
that state available for reopening.

Squash groups pause in the Commit Message tab for multiline editing and Continue
approval. Advanced `SquashDate` controls the author date; the first author is kept.
See [Squash workflow](REBASE-SQUASH.md).

This is a partial port. Full conflict tabs, Split, author overrides,
complete keyboard/accessibility parity, displayed acceptance checks and
signed App Store execution remain unfinished. See the [parity audit](CHERRY-PICK-PARITY.md)
for the verification scope. Current macOS screenshots are pending.
