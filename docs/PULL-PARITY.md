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
can leave a merge ready for completion. Git errors preserve controls and offer
Open Working Tree to inspect the captured repository. Merge conflicts retain Git's
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
separate Fetch/Rebase route. The current focused Pull/Fetch tests passed all 14 checks within the 17-test
run that also covers registered-parent metadata.

Native QA pulled a real new commit from the disposable documentation remote with
Fast Forward Only selected. HEAD advanced, the remote file appeared, and original
index/worktree patches matched byte-for-byte. Mutual fast-forward enablement and
preference restoration were checked. The early temporary configured-rebase check predates the implemented
Fetch/Rebase handoff described above.
A missing URL produced an error; Open Working Tree opened the correct status window.
`site/assets/pull.png` captures the actual native window before its successful pull.

## Remaining comparison work

- Full fast-forward choices, post-operation actions and continue/abort recovery.
  Fetch → Rebase routing and configured auto-start are implemented; native
  preserve-merges/configured-mode combinations still need broader QA.
- Progress/cancellation and full post-operation actions: compare old/new revisions,
  filtered Log, Push, submodule update, stash, reset and unrelated-history retry.
- Native squash/No Commit/divergence/conflict completion and abort QA; the tests
  prove Git effects but not those full native workflows.
- Full remote reference chooser and settings,
  additional preference/size persistence, light/resize/keyboard/accessibility QA.
  Shared URL/branch history is now implemented; clipboard/deletion acceptance remains pending.
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
