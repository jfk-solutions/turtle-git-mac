# Replay, merge and resolution inspection engines

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
This connected family concerns selected inspection operations, not a replacement
sequencer, a blanket interception of Git commands, or complete dialog parity.

## Source gates and eligible decisions

`Git.cpp::IsFastForward` (line 2694) selects MergeBase command 7. It resolves two
commits, obtains one common ancestor, returns that ancestor when requested, and
compares it with the starting commit. Rebase planning/fast-forward verification,
Fetch/Rebase follow-ups, Sync outgoing comparisons and SVN rebase decisions use
this source-shaped decision. Structural queries that require **all** merge bases
retain their existing Git reader.
The Changed Files common-ancestor option also uses this decision, matching
`FileDiffDlg.cpp:308`; it retains the direct range for divergent commits.

`Git.cpp::CheckCleanWorkTree` (line 2620) selects command 12. An unborn HEAD is
unclean. The selected status flags update the index cache and exclude submodules;
untracked files are omitted. `stagedOk` chooses working-tree-only inspection or
both staged and working changes. Rebase start, checkout verification, Edit/Squash
continuation, commit loops, replay stash decisions and SVN readiness are eligible
callers. The apparent Log commit-revert clean guard is inside `#if 0` in
`GitLogListAction.cpp`; enabling it would change source behavior.
The `stagedOk` Edit decision applies when the next remaining commit is not a
Squash. Staged-only edits continue through normal amendment; unstaged edits open
the checked-file Commit selection. The structural empty-Squash Skip guard stays
independent so an index-lock failure can retain its approved recovery intent.

`Git.cpp::HasWorkingTreeConflicts` (line 2675) selects command 13 and reads actual
index conflict presence. An index-read error is distinct from a clean result.
Rebase verification and Merge/Switch/Sync completion use the Boolean decision;
displaying the actual conflict list remains a separate read.

`ResolveProgressCommand.cpp:81/132` selects GetConflictInfo command 17 for
**Mine/Theirs** only. Current resolution returns before this gate. Requested-path
stage lookup distinguishes a missing conflict (Skip), absent selected stage
(deletion), ordinary blobs/links and gitlinks. The selected stage's full object ID
and mode determine the subsequent operation. It does not replace every
`ls-files` conflict listing, conflict editor input or ordinary staging reader.

The source default mask enables 7, 13 and 17 and leaves 12 off. The master switch
can select the Git command branches independently of these per-command defaults.
GetCommit14 remains a separate detail-reading family because its string-based
source eligibility, declared encoding and full message semantics differ.
The source default mask enables14 too; its native single-commit consumers still
use their current Git readers until that separate family is ported.

## Connected native behavior

The accepted workflow captures its backend before asynchronous preparation,
choices or child windows. Rebase, Fetch/Sync rebase follow-ups, Merge/Switch
completion, Resolve Mine/Theirs and SVN readiness keep that choice through owned
inspection, cancellation and recovery. A result inspection after ordinary command
cancellation uses a fresh owned token; forced window retirement cancels that read
as well. Errors must not manufacture a conflict-free or clean result.
Closing a completed Merge result is a new accepted action: its fresh conflict
inspection captures the current settings before awaiting that dismissal read.
It does not reuse or change the completed merge attempt's captured settings.

The helper uses bounded typed replies for a single common ancestor, clean state,
conflict presence and requested stage tuples. Source-selected inspection does not
select a new merge/rebase mutation engine. Existing reviewed checkout, add,
removal, submodule handling, stale-stage checks and permissions remain in the
owning workflow. Mine/Theirs skips an already-resolved missing conflict without
changing it, and refuses changed nonmissing stages before mutation. Current keeps
its independent semantics.

## Validation and remaining scope

The [dated checkpoint](qa/replay-inspection-2026-10-20.json) records passing
evidence for 208 distinct relevant Core methods, actual universal-helper checks,
the final Debug app and all six native workflow cases with both Git versions.
The original Core group exposed two structural Skip regressions; their repair
and the actual Edit decision passed a focused 21-method recheck. Native fixture
and actor-isolation repairs are retained in that record. Only affected checks
were repeated. Physical
keyboard/accessibility, installed signed grants, external filter combinations,
minimum-version/runtime acceptance, complete hosted integration and full upstream
application parity remain independent gates.

Further source consumers outside this connected family still need review:
Log ancestry navigation (`LogDlg.cpp:2641–2751`), submodule comparison direction
(`GitDiff.cpp:335/338`), local branch deletion ancestry warnings
(`BrowseRefsDlg.cpp:681`, `AppUtils.cpp:3855`), and the active Log action clean
guard (`GitLogListAction.cpp:643`). Completing the four helper primitives does
not by itself port every caller of those primitives.
That active clean guard belongs to **Combine commits**, not commit reversion.
Its native preparation/execution, Log fast-forward Jump Up/Down, submodule
forward/rewind classification and shared deletion warnings form the remaining
history/navigation continuation.
