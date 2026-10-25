# Rebase conflict commit and message phases

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseProc/RebaseDlg.cpp` at 1375–1565 and
`src/TortoiseProc/AppUtils.cpp` at 2210–2264. This is a connected part of the
partial native `IDD_REBASE` Rebase and Cherry Pick workflow.

## Source order

Ordinary Pick/Edit conflict continuation checks unresolved files and message
conflict hints before preparing the selected file queues. It creates the first
commit with `--allow-empty-message -C <original commit>`. That preserves Git's
original-message and author handling. Git's `-C` skips leading blank message
lines before its prepare-message hook; preserving the original source bytes does
not imply that Git reproduces those leading blank lines in the new commit.
A failure at this boundary is an ordinary
error; it does not offer Ignore.

Only after that commit succeeds does the source trim the raw editor message and
compare it with the trimmed original message. An unchanged message needs no
second commit. A changed, empty raw message reports an error after the original-
message commit has already succeeded. A changed nonempty message is prepared
using the configured message cleanup and encoding, then submitted to a separate
`commit --amend -F` operation. Cleanup happens after the comparison; a cleaned
message equal to the original still takes the second operation. A cleanup result
that is empty reaches Git's failure path.

An unsuccessful second amendment offers default Retry and Ignore only when the
tracked index and worktree are clean. Dirty failures remain ordinary errors.
Unchecked-file restoration follows successful message handling or Ignore. The
original Edit action then pauses for review; Pick resumes replay. Squash-conflict
continuation has its own staged path and is not this checked Pick/Edit family.

## Native implementation and recovery adaptation

The native controller separates the selected original-message commit from the
optional edited-message amendment. It retains the raw draft across the boundary,
including Undo, and uses the displayed conflict rows and inherited unchecked-file
preference for the source index queues. After independently checking that the
prepared real index matches the selected tree, the native source-policy route
commits that real index so the first hooks retain their index changes. The second
amendment must not absorb unselected staged content. Hook changes made by the
first commit belong to the actual applied commit and survive the second phase.

A durable phase records intent before the first command, then its actual applied
HEAD, source occurrence, requested action, raw draft and remaining restoration
work. Reopening or Retry must not silently repeat the initial commit. If a
cancelled command may have published a commit but its result cannot be safely
identified, the workflow refuses automatic continuation and requires inspection
or Abort. Stale session, HEAD, index and metadata are not approval to amend.

This durable phase is a macOS recovery adaptation. The pinned Windows Retry
returns while its in-memory stage is still Conflict and can re-enter the initial
commit path on a subsequent Continue. We retain the successful two-command hook
order and Retry/Ignore choices without reproducing that duplicate-initial-commit
risk. The older combined Core convenience API retains its explicit applied-
review return contract and selected-index behavior when no source row policy is
supplied; the native two-phase route owns the source Pick/Edit
outcome. Restored unchecked tracked changes cannot be passed blindly to Git's
sequencer, which could otherwise commit them implicitly. A Pick with leftovers
therefore enters the existing checked Commit amendment review; cancellation and
reopening retain that review, and Pick resumes once its tracked tree is clean.
This is a native sequencer adaptation, not an extra automatic commit.
An original empty subject retains the earlier empty-message workflow's mandatory
applied review even when its requested action is Pick. Reusing the original raw
message for the first command does not approve skipping that review.

The older combined API also retains its explicit empty-result permission during
its secondary amendment. The native two-phase route follows the source command:
that optional amendment does not add `--allow-empty`, so an empty-result rejection
uses the ordinary dirty error or clean Retry/Ignore boundary.

Git's sequencer invokes `prepare-commit-msg` before the deferred Squash editor,
while the source applies group members without committing until message approval.
The native transport therefore uses a temporary hook directory only for an owned
deferred Squash preparation with an executable original prepare hook. Bypass is
limited to the captured session, immutable message configuration and exact
completed-command boundaries, including repeated occurrences. The original hooks
remain active for explicit message commits. Other hooks are forwarded to their
original executable with their arguments and working directory. Forwarding clears
the private bypass nonce and restores configuration parameters from before the
temporary hook override so nested Git does not inherit another repository's
temporary hooks. Guard data uses a private subdirectory to avoid collisions with
executable helpers in a user's hooks directory. No repository configuration is
persistently changed.

## Validation and remaining work

The [grouped checkpoint](qa/rebase-conflict-message-2026-10-25.json) records 47
distinct selected Core methods cumulatively passing across focused repairs, all
six native case/Git pairs passing and the final Debug build. The first/second
command ordering, actual critical Retry/Ignore sheet and default button,
reopening, empty draft correction, cancellation and stale-owner refusal are
covered separately from displayed layout. Every attempted receiver was reaped
and independently absent. No complete Core or hosted suite was repeated locally.

The repaired deferred Squash cases also pass with system and bundled Git. They
check a following group, contiguous members, original prepare-hook counts,
forwarded post-commit hooks and a nested repository's own hooks. Explicit final
message approval still reaches the original rejecting hook. These Core cases
exercise the bridge; the native families cover ordinary Pick/Edit continuation
with no prepare-message hook. The final app build includes the bridge repair.

Recorded failures distinguish production behavior from fixture mistakes: mandatory
empty-subject review, legacy empty-result permission, premature Squash hook timing
and literal configured hook invocation needed implementation repairs. Native
fixtures needed an interpolation correction and actual acknowledgement of their
existing error alerts. Git's leading-blank `-C` normalization needed a corrected
oracle while preserving exact source-byte and mandatory-review assertions. Passing
families were retained; only affected failures were rechecked.

Full conflict-tab layout and conditional menus, physical keyboard/VoiceOver,
signed installed replay, minimum supported macOS, physical Intel execution,
complete hosted integration and full application parity remain open.
The hook bridge's repeated-hash, structural and forced-empty group combinations,
configured-relative/default hook invocation paths and arbitrary asynchronous hook
behavior are not established by the focused contiguous-group case. Exact
metadata guards are implementation constraints, not evidence of every combination.
