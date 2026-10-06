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
multiple rows. The first retained entry cannot be Squash. Adding further commits
inside an existing plan is still pending; close the plan and select them in Log.

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

This is a partial port. Full conflict tabs, Add/Split, squash message and author/date
choices, complete keyboard/accessibility parity, displayed acceptance checks and
signed App Store execution remain unfinished. See the [parity audit](CHERRY-PICK-PARITY.md)
for the verification scope. Current macOS screenshots are pending.
