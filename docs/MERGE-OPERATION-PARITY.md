# Merge operation and message preparation

Source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This is a focused `IDD_MERGE` workflow audit, not a claim that every Merge,
Switch, Reset or TortoiseGitMerge resource is complete.

## Pinned source mapping

| Source | Native/Core behavior |
| --- | --- |
| `AppUtils.cpp:3378–3394`, `CheckUserData`, `IsTGitRebaseActive` | User Merge prepares identity before refusing an owned replay; Git Settings repair rereads identity. Submission rechecks preparation and Core rechecks immediately before mutation. |
| `AppUtils.cpp:2465–2719`, `RebaseAfterFetch` | Internal Fetch fast-forward does not acquire a new user Merge identity requirement. `MergeOptions.requireIdentity` defaults false; the user Merge dialog captures true. |
| `AppUtils.cpp:3231–3273`, `DoMerge`, `SaveCommitUnicodeFile` | Custom enabled Merge Message uses a private encoded `-F` file, rather than Git `-m`. The file is removed after success, error or cancellation. |
| `AppUtils.cpp:2210–2268`, `SaveCommitUnicodeFile` | Reuses `CommitMessageFile.format` and `CommitMessageEncoding`; `StripCommentedLines` defaults false, `SanitizeCommitMsg` defaults true, `core.commentchar` controls prefix stripping and `i18n.commitencoding` controls bytes. Each retained line ends in LF. |
| `AppUtils.cpp:3340–3371`, successful post commands | No Commit/Squash offers Commit and returns; fully committed Git SVN integration offers SVN DCommit after the branch actions. |
| `MergeDlg.cpp`, `TortoiseProcENG.rc:1370–1403`, `IDD_MERGE` | Existing branch/tag/commit selectors, Message/History, No FF/FF Only/Squash/No Commit controls and recursive strategy options are retained. Strategy lists are closed dropdowns upstream, not arbitrary editable strategy names. |

## Implementation contract

`GitRepository.prepareMerge(cancellation:)` returns public `MergePreparation`
with `ReplayUserIdentity`, `replayActive` and `hasGitSVN`. Identity lookup shares
the pinned CheckUserData implementation, including its source environment
precedence. The preparation result is a snapshot; it cannot authorize a later
mutation. Native repair loops and submission rereads retain their operation
cancellation and repository access ownership.

The final `merge` check refuses an active native-owned replay independently of
the identity flag. It reads TurtleGit session, sequence identity and cherry-pick
markers inside Git-resolved `rebase-merge`/`rebase-apply` directories. It does not
invoke `rebaseState` transaction recovery, discard replay metadata, or let Git
report “already up to date” while an owned Edit phase remains active. It works
with worktree-specific replay directories. Git SVN detection uses the common
Git directory, matching the existing repository metadata behavior.

The existing options and author semantics remain Git's: no forced author/date,
no extra cleanup override, no replacement of the selected canonical ref with a
hash in the generated merge message. Git's own message cleanup, hooks, log
appending, fast-forward, conflict and no-commit behavior still apply after source
file preparation. Squash ignores the disabled Merge Message, even if that draft
contains text or a configured encoding is unavailable. Invalid message encoding
fails before index/ref mutation.

The internal message-file helper now accepts an optional cancellation token;
configuration lookup and encoding preparation obey the owning Merge operation.
Other consumers retain their existing default call contract.

## Evidence and limits

New focused Core class: `MergeOperationTests`. Its private real repositories cover
the resulting commit's Windows-1252 bytes and comment/sanitize behavior, invalid
encoding refusal before mutation, ignored Squash message, explicit user identity
versus internal fast-forward, and refusal of a real paused TurtleGit Edit replay
without changing its files. Existing `MergeTests` covers flags, conflicts,
unrelated-history retry, strategy behavior and no-commit recovery.

Native fixture: `qa/merge-operation-native-2026-10-18.swift`,
`MergeOperationVerification.verify()`. It covers a real local merge and message
cleanup, SVN metadata completion action without network invocation, the actual
Git Settings OK repair and parent-close cancellation, late replay refusal, actual History
selection/OK and duplicate reply retirement, deferred Quit and a late
noncooperative preparation. Merge form receipts retire obsolete control/editor
callbacks; preparation, History and progress sheets retain their operation/access
ownership until return. Hidden child sheets inherit owner alpha and appearance.
The parent records the grouped build/Core/native results after implementation
freezes. No test or build was run as part of this file's implementation work.

Explicit remaining differences/limits:

- Upstream offers removal of the Windows-only `tgitrebase.active` directory as a
  stale-marker repair. Native Merge refuses its actual TurtleGit-owned replay;
  it does not delete a replay or import that legacy Windows marker protocol.
- Native sheets and repository access grants replace Win32 modal ownership.
  Automated hidden fixtures do not establish every physical light/dark layout,
  Finder deployment, actual SVN-server DCommit, or every upstream dialog's parity.
- Commit-message encodings unavailable to the existing macOS encoding adapter
  fail before mutation rather than silently changing the requested bytes.


The [grouped checkpoint](qa/credential-merge-workflows-2026-10-18.json) records
24 passing selected Core cases and 14 distinct passing native case/engine
combinations, including focused repairs and retained unaffected results. This
scoped pass does not remove the remaining acceptance limits above.
