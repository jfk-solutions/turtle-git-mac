# Pull dialog parity

Reference: `PullFetchDlg.cpp`, `IDD_PULLFETCH`, PullCommand and `CAppUtils::Pull/DoPull`
at the pinned commit in `upstream.json`. Native Pull and Fetch share their window
implementation, as upstream does.

## Implemented

Pull retains the Remote, arbitrary URL and editable branch/browse rows, followed
by Squash, No Commit, No Fast Forward, Fast Forward Only, three-state Tags/Prune,
conditional shallow Depth, Manage Remotes and bottom OK/Cancel/Help. Pull offers a
single remote, and branch selection remains enabled. No Fast Forward and Fast
Forward Only disable each other. The Fast Forward Only preference is remembered.
The basic Manage and remote-head chooser are shared with Fetch.

The backend uses explicit `--no-rebase`, as upstream's merge Pull does. Native
Git merge message editing is suppressed with `--no-edit`; Git supplies its default
message. For the configured tracked remote/branch, the default refspec is retained
rather than forcing a branch argument. Other selections send the explicit branch.
Squash stages the result without creating MERGE_HEAD or advancing HEAD; No Commit
can leave a merge ready for completion. Pull errors are retained in an owned progress sheet with source recovery
actions; the selected options remain locked behind it. Merge conflicts retain Git's
normal unmerged index and MERGE_HEAD; resolution/abort parity remains incomplete.

Configured `branch.<name>.rebase` takes precedence over `pull.rebase`. Named-remote
Pull routes configured rebase through an explicit selected-branch Fetch and the
native Rebase plan, with auto-start and a locked checkbox. `merges`/`preserve`
configuration enables Preserve Merges. Explicit URL mode clears rebase and
performs merge Pull, matching upstream's radio behavior. See REBASE-PARITY.md for
handoff evidence and remaining differences.

## Evidence

Five real Git integration tests cover fast-forward pulls preserving unrelated mixed
staged/unstaged changes, forced merge commits, No Commit and subsequent completion,
squash staging without a merge parent, diverged ff-only rejection, a true merge
conflict and Git abort, URL branch selection, configuration precedence, backend rejection of unsupported automatic rebase
without mutation and invalid flags/refspec input. Native configured Pull uses the
separate Fetch/Rebase route. The current focused Pull/Fetch tests passed all 18 checks within the 21-test
run that also covers registered-parent metadata.

Native QA pulled a real new commit from the disposable documentation remote with
Fast Forward Only selected. HEAD advanced, the remote file appeared, and original
index/worktree patches matched byte-for-byte. Mutual fast-forward enablement and
preference restoration were checked. The early temporary configured-rebase check predates the implemented
Fetch/Rebase handoff described above.
A missing URL produced an error; Open Working Tree opened the correct status window.
`site/assets/pull.png` captures the actual native window before its successful pull.

## Remaining comparison work

- Full interactive Rebase continue/abort recovery and remaining operation workflows.
  Fetch → Rebase routing and configured auto-start are implemented; native
  preserve-merges/configured-mode combinations still need broader QA.
- Live streaming and physical owned-progress/menu/close acceptance, source conflict
  result See changes question, full submodule and signed post-action handoff acceptance.
- Native squash/No Commit/divergence/conflict completion and abort QA; the tests
  prove Git effects but not those full native workflows.
- Full remote reference chooser and settings,
  additional preference/size persistence, light/resize/keyboard/accessibility QA.
  Shared URL/branch history is now implemented; physical clipboard/deletion acceptance remains pending.
- Interactive Git hooks, authentication/signing and signed sandbox runtime checks.

The shared resource and command sources remain partial. This is not full Pull
parity or an App Store-ready release.

Configured rebase is now routed through an explicit branch Fetch and native Rebase,
with its locked checkbox and merge-only options disabled. `merges`/`preserve`
configuration enables Preserve Merges. Native configured Pull on a disposable
repository reached Rebase finished; Git verified the local commit's parent was
the selected fetched commit, branch identity was unchanged and the worktree clean.
The prior disabled-OK check above and screenshot describe the earlier build.
See REBASE-PARITY.md for the exact handoff and remaining workflow differences.

Shared native URL/branch history now follows the PullFetchDlg controls and persists
across Pull/Fetch and repositories, including failed transport. See the history
section in FETCH-PARITY.md for exact source rules and remaining acceptance.

Registered submodule branch defaults now follow the parent `.gitmodules` value
when the child has no tracking branch. See FETCH-PARITY.md for exact source
precedence, literal-dot behavior and remaining acceptance.

Arbitrary URL now prefills from copied Pull/Fetch text with the shared source
parser and macOS path/file-URL additions. See FETCH-PARITY.md for the exact rules
and remaining physical pasteboard acceptance.


Transport Cancel now stops the operation's owned process group, optionally asks
the shared ConfirmKillProcess question. Fetch-before-Rebase now shares owned
Fetch progress and closes after accepted cancellation finishes;
merge-based Pull now closes its owned progress/options after accepted cancellation
finishes. Cancelled configured-rebase Fetch does not open Rebase. See FETCH-PARITY.md for source
mapping, native evidence and remaining cancellation/progress acceptance.

## Owned Pull progress and follow-up actions

Merge-based Pull now retains its output/result in an owned resizable native
progress sheet. Options remain locked until that result closes; repeated OK
cannot execute again. Every command owns a fresh options window, preserving other
drafts and caller follow-up flags. Closing completed progress closes its options
owner. Busy Cancel uses the same optional ConfirmKillProcess Yes/No question and
owned process-group cancellation; accepting Cancel closes Pull progress and its
options owner after the operation finishes. Fetch and Fetch-before-Rebase keep their existing
source decisions; upstream does not carry Pull's Stash Pop/Push flags into DoFetch/Rebase.

Successful Pull offers requested Stash Pop, Pulled Diff, Pulled Log, requested Push,
then applicable Submodule Update, in source order. Compare receives the immutable
old/new HEAD hashes; Log receives `old..new`. An unchanged or No Commit result still
offers those hash-based views, matching source. Pull does not add a Commit button
for No Commit/Squash; finishing those merges remains the existing Commit workflow.

Failed Pull with actual conflicts awaits the shared merge information/suppression
sheet, then offers only Resolve and Commit. Other failures offer explicit Merge
unrelated history when a named remote's common ancestor hash stays empty, followed
by Pull, Stash Save and Reset. This includes a missing remote ref as upstream does;
URL failures do not get the unrelated action. That retry preserves captured flags
and adds `--allow-unrelated-histories`, without automatically accepting unrelated
history. Pull opens fresh options; Stash Save requests a return Pull. Reset reads
the current tracked upstream and opens native Reset with Hard selected, without
resetting before confirmation. Source's optional post-result See changes question
still needs its native implementation.

Stash Save's Pull action now uses a shared follow-up conversion: Push follows the
saved `pullShowPush` flag and Stash Pop is requested, as upstream does even when
saving created no new stash. Source recovery actions, Compare/Log, Push, Pop and
Submodule Update route to the existing native destination dialogs with the retained
repository access. Result callbacks refresh repository Log/RefLog/Commit/Status
views. Store builds check security scope before Pull transport, Reset-default reads
and native Stash Apply/Pop mutation. These are preparation gates, not signed runtime
acceptance.

[Native model QA](qa/pull-progress-native-2026-10-08.swift) and
[the record](qa/pull-progress-2026-10-08.json) cover option/follow-up snapshots,
retained result/close and duplicate guards, old/new HEAD, unchanged/No Commit,
conflict-hint blocking and shared suppression, exact recovery action lists, fresh
Reset defaults without mutation, unrelated retry producing both parents, missing
ref versus URL behavior, and real Stash Save → Pull → Pop restoration through the
shared callback conversion. Core adds an unrelated-history integration case.
Existing cancellation/history receivers also passed. The chain uses actual models
and Git, with the final Pop backend called after its callback; no destination
controller or installed app is activated. Physical sheets/buttons/keyboard/close,
source result questions, submodules, streaming, screenshot updates, signing and
full application parity remain incomplete.

Configured automatic Rebase bypasses the new manual Fetch/Rebase questions and
forwards auto-start/preserve-merges. Manual Fetch/Rebase now offers source
up-to-date/unchanged/fast-forward choices; see FETCH-PARITY.md for real Git
evidence, retained results and remaining physical/signed acceptance.


## Live merge-Pull output

Merge-based Pull now forwards CLI stdout/stderr through the same source parser
and native presentation as Fetch. The progress model captures its display limit,
shows phase/percentage while the owned command is running, and retains complete
raw diagnostics independently of visible truncation. Existing conflict detection,
Resolve/Commit, non-conflict recovery, old/new HEAD comparison and Stash/Push
follow-ups use their original repository/result logic. Explicit unrelated-history
retry resets bytes/phase/truncation and creates a fresh parser and cancellation
token. Rebase-configured Pull uses the streamed Fetch/Rebase route described in
[Fetch parity](FETCH-PARITY.md#live-fetch-and-fetchrebase-output).

[Live-output QA](qa/fetch-pull-stream-2026-10-08.json) records complete raw observer
results, real fast-forward HEAD/tracking and mixed-change preservation, Unicode
split across writes, remote CR replacement and phase/percentage before an owned
helper exits, hidden native layout, No/Yes process cancellation, and captured
16 KiB truncation retaining full diagnostics and non-conflict recovery. Existing
Pull progress checks cover conflict/non-conflict decisions and unrelated retry
through the new stream path. No displayed UI or real remote cadence is claimed.

Physical scrolling/defaults/focus/keyboard/themes/accessibility, full progress
controls, source project hooks, real network/authentication, signed folder grants
and Finder/App Store acceptance remain pending. Screenshots predate streaming;
full Pull/application parity remains incomplete.
