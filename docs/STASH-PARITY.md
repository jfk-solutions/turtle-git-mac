# Stash Save parity

Reference: pinned TortoiseGit `StashSave.cpp`, `StashSave.h`, `IDD_STASH`,
`AppUtils::StashSave` and the [official manual](https://tortoisegit.org/docs/tortoisegit/tgit-dug-stash.html).
This is a partial port, not complete Stash workflow parity.

## Implemented

The native window retains the Stash Message group with a single-line optional
message, followed by Options containing `include untracked` and `--all`. Each
checkbox disables the other. The footer provides OK, Cancel and Help. Empty
messages are accepted and use Git's default description. The repository access
lease is retained throughout the operation, and open status/log/Commit views reload.

Include-untracked presents an Abort/Continue sheet. Abort leaves the dialog open.
The suppression preference is stored only after Continue with suppression checked.
The warning describes saving and removing untracked files; its wording is adapted
to Git's actual behavior rather than the upstream resource's misleading reference
to removing ignored files. `--all` includes ignored files as documented.

Whole-repository save explicitly disables literal pathspec mode. Git internally
runs clean with its own `:/` magic pathspec; inheriting literal mode saved files
but silently skipped cleanup. No user-supplied pathspec is accepted by this save
operation. Other repository commands retain their default literal path handling.

## Evidence

Four integration tests cover separate staged/worktree contents, unchanged HEAD,
Unicode/newline and leading-dash filenames, optional and custom messages,
untracked/ignored inclusion and cleanup, restoration with `stash apply --index`,
invalid option combinations and no-change detection. The full local suite passed:
108 tests, zero failures (including the four restoration tests below).

Native QA used `/private/tmp/TurtleGitStashSaveQA`, a disposable mixed-change
repository. Both checkbox enablement directions were observed. OK accepted an
empty message. Checking suppression then Abort left options intact; accepting
again presented a fresh unsuppressed warning. Continue saved separate `staged`
and `working` contents in the expected stash parents, removed the untracked file,
and preserved the ignored file. After restoring the fixture, native `--all` with
`Native all-files stash` saved and removed both ignored and untracked files.
HEAD remained `74942b2bab92834cf7bc7aae8d58cfd5d04f9f20` throughout.

`site/assets/stash-save.png` is an actual light native window capture, not a mockup.

## Apply and Pop

`AppUtils::StashApply` and `AppUtils::StashPop` run immediately, followed by a
success/conflict Yes/No prompt asking whether to show changes. TurtleGit now uses
that workflow instead of a generic pre-operation confirmation. Yes opens the
repository's Working Tree window using the same retained access lease. Normal
errors use an error sheet; status/log/Commit views reload after either outcome.
Apply and Pop share the original unshelve menu artwork. Apply is now exposed in
the app, Working Tree Stash menu and Finder command routing. Signed Finder QA
remains pending.

Apply retains the stash. Pop delegates removal to Git so a conflicted or failed
application retains it. Neither defaults to `--index`, matching upstream.
Selected Apply's core API resolves a commit before invoking Git and normalizes
upstream `refs/stash@{n}` and `stash{n}` forms. Its native selection UI is pending.
Conflict classification requires Git exit 1, conflict output and actual unmerged
entries; other nonzero exits remain errors. Pop's remembered Yes/No answers use
separate success/conflict preferences; Apply always presents its prompt.

Four additional integration tests cover default Apply/Pop index semantics,
untracked/ignored restoration, successful Pop removal, conflict retention and
unmerged stages, selected older Apply without dropping the latest stash, missing
stashes, overwrite prevention and rejection of option-like references.

Native QA repositories were `/private/tmp/TurtleGitStashRestoreSuccessQA` and
`/private/tmp/TurtleGitStashRestoreConflictQA`. Apply restored `stashed` contents,
left the index clean, retained HEAD/stash and opened Working Tree after Yes.
After resetting only this disposable fixture, Pop restored the file and removed
the sole stash; No with Remember my answer closed its result window. A divergent
HEAD fixture produced the conflict prompt, Yes opened Working Tree with the
conflicted file, and Git confirmed unchanged HEAD/stash plus all three unmerged
index stages. Native Cancel in Save was also checked after the preceding Save QA
and left stash/HEAD/working state unchanged.

`site/assets/stash-pop.png` captures the actual successful native Pop prompt.
A later conflict-capture attempt encountered native observation timeouts while
the QA app remained running. The earlier conflict prompt/handoff and Git effects
were verified; no conflict prompt image is published.

## Remaining

- Full progress/cancellation and upstream conditional Pull/Merge/Pop/Apply post-actions.
- Native stash list, selected Apply/Pop/Drop, inspection and branch-from-stash workflows.
- Explicit user-data guard matching the upstream pre-dialog flow.
- Native Continue suppression persistence/relaunch and window-close invariants,
  horizontal resizing and dark appearance QA.
- Signed sandbox/Finder invocation and App Store runtime validation.

Native Pop remembered-answer relaunch/automatic handoff, error-sheet dismissal,
full cancellation/progress behavior and multi-repository handoffs need broader QA.
