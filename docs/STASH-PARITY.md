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
104 tests, zero failures.

Native QA used `/private/tmp/TurtleGitStashSaveQA`, a disposable mixed-change
repository. Both checkbox enablement directions were observed. OK accepted an
empty message. Checking suppression then Abort left options intact; accepting
again presented a fresh unsuppressed warning. Continue saved separate `staged`
and `working` contents in the expected stash parents, removed the untracked file,
and preserved the ignored file. After restoring the fixture, native `--all` with
`Native all-files stash` saved and removed both ignored and untracked files.
HEAD remained `74942b2bab92834cf7bc7aae8d58cfd5d04f9f20` throughout.

`site/assets/stash-save.png` is an actual light native window capture, not a mockup.

## Remaining

- Full progress/cancellation and upstream conditional Pull/Merge/Pop/Apply post-actions.
- Native stash list, selected apply/pop/drop, inspection and branch-from-stash workflows.
- Explicit user-data guard matching the upstream pre-dialog flow.
- Native Continue suppression persistence/relaunch, Cancel/window-close invariants,
  error recovery, horizontal resizing and dark appearance QA.
- Signed sandbox/Finder invocation and App Store runtime validation.
