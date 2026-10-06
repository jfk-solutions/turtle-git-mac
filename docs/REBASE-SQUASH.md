# Squash messages and author dates

Select **Squash** for a commit to combine it into the preceding retained commit.
The first retained entry cannot be Squash. Rebase and Cherry Pick pause at the end
of each squash group and show an editable multiline **Commit Message** tab. Review
the combined message and choose **Continue** to approve it. Blank messages are
rejected. Literal comment-prefixed lines and Unicode in the approved message are
preserved. The pause uses Git's replay metadata; reopening restores the combined
message and operation mode. Changes typed before closing are not saved until
Continue attempts approval.

The combined commit retains the first commit's author. In **Settings → Advanced**,
`SquashDate` chooses the author date, matching upstream:

| Value | Author date |
| --- | --- |
| `0` (default) | First commit in the group |
| `1` | Last commit replayed into the group |
| `2` | Current time when the message is approved |

The setting is captured when the plan is loaded and retained for recovery.
Committer dates continue to follow Git's normal behavior. An earlier Edit action's
amended message becomes part of the squash message. Each separate group requires
its own approval. Abort restores the original branch and HEAD; ordinary conflict
resolution and staging still take place through Working Tree.

## Implementation and remaining work

Git invokes TurtleGit's own executable as a headless message editor. It records a
pending request and exits unsuccessfully to leave the replay paused. The native
window treats that request as an editing state rather than an error alert. Git's
combination headings are removed from the default message; approved text is
committed with verbatim cleanup. Approval amends Git's current partial combined
commit with the selected author date, then resumes the persistent todo. Git hooks
and signing configuration are not disabled. A failed commit leaves the request
and attempted draft available for recovery.

The metadata lives in the worktree's own `rebase-merge` directory, including for
linked worktrees. Requests are tied to their replay step so Skip cannot expose a
stale message as a later commit's editor. [Split](REBASE-SPLIT.md) now opens full
Commit selection dialogs at Edit or squash pauses. Complete conflict tabs, empty
combined-commit choices, author overrides and full displayed keyboard/layout/
accessibility acceptance remain unfinished. Signed sandbox execution and App Store
acceptance are not established.

## Verification

27 focused Rebase tests pass, including all three date policies, first-author/tree
preservation, blank-message rejection, reopening, conflict-to-squash Abort,
linked-worktree isolation, two group approvals with an earlier Edit message,
failed-hook draft recovery and stale-request protection after Skip. The
whole-native receiver passes with Git 2.37.1, 2.39.5, system 2.50.1 and packaged
2.55.0. It hosts the actual multiline editor, checks the captured Advanced
preference, suppresses the expected editor-failure alert and approves exact
Unicode/comment text through Continue. Events and operations are injected;
displayed dialogs and gestures are not verified. Unsigned Debug/App Store builds,
bundle audits, exact NOTICE comparisons and site generation pass. Recorded scope
and hashes: `qa/rebase-squash-2026-10-06.json`.

Pinned upstream references: `src/TortoiseProc/RebaseDlg.cpp` (Squash_Edit,
`m_SquashFirstMetaData` and `m_iSquashdate`), and
`doc/source/en/TortoiseGit/tgit_dug/dug_settings_advanced.xml` (`SquashDate`).
