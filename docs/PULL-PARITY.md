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

Configured `branch.<name>.rebase` takes precedence over `pull.rebase`. Upstream
routes this to Fetch + its interactive Rebase workflow. That workflow is pending:
the native checkbox is checked/disabled for configured rebase, an explanation is
shown and OK is disabled. Named-remote backend calls also reject before fetching or merging. Explicit URL
mode clears rebase and performs merge Pull, matching the upstream radio behavior.
This remains an explicit missing workflow, not a replacement with automatic rebase.

## Evidence

Five real Git integration tests cover fast-forward pulls preserving unrelated mixed
staged/unstaged changes, forced merge commits, No Commit and subsequent completion,
squash staging without a merge parent, diverged ff-only rejection, a true merge
conflict and Git abort, URL branch selection, configuration precedence, configured
rebase rejection without mutation and invalid flags/refspec input. The full suite
has 76 passing tests.

Native QA pulled a real new commit from the disposable documentation remote with
Fast Forward Only selected. HEAD advanced, the remote file appeared, and original
index/worktree patches matched byte-for-byte. Mutual fast-forward enablement and
preference restoration were checked. A temporary configured rebase showed its
checked unavailable control and disabled OK; the fixture configuration was restored.
A missing URL produced an error; Open Working Tree opened the correct status window.
`site/assets/pull.png` captures the actual native window before its successful pull.

## Remaining comparison work

- Full Fetch → interactive Rebase, preserve-merges/configured modes, fast-forward
  choices and continue/abort recovery. User-selected Rebase launch is disabled.
- Progress/cancellation and full post-operation actions: compare old/new revisions,
  filtered Log, Push, submodule update, stash, reset and unrelated-history retry.
- Native squash/No Commit/divergence/conflict completion and abort QA; the tests
  prove Git effects but not those full native workflows.
- Full remote reference chooser and settings, histories, submodule defaults,
  additional preference/size persistence, light/resize/keyboard/accessibility QA.
- Interactive Git hooks, authentication/signing and signed sandbox runtime checks.

The shared resource and command sources remain partial. This is not full Pull
parity or an App Store-ready release.
