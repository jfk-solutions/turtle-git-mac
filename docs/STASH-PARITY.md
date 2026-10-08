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
upstream `refs/stash@{n}` and `stash{n}` forms. Its native RefLog selection UI is now implemented and exercised; see REFLOG-PARITY.md.
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

- Physical progress/sheet/cancellation acceptance, live output streaming, and downstream Pull follow-through flags (subsequent Pop/Push choices).
- RefLog now provides native list, selected Apply, inspection and guarded Drop/Clear.
  Selected Pop, branch-from-stash and broader deletion/recovery QA remain pending.
  See REFLOG-PARITY.md.
- Explicit user-data guard matching the upstream pre-dialog flow.
- Native Continue suppression persistence/relaunch and window-close invariants,
  horizontal resizing and dark appearance QA.
- Signed sandbox/Finder invocation and App Store runtime validation.

Native Pop remembered-answer relaunch/automatic handoff, error-sheet dismissal,
full cancellation/progress behavior and multi-repository handoffs need broader QA.

## Save progress and conditional post-actions

Stash Save now keeps command output and its result in an owned native progress
sheet. The options remain fixed behind that sheet until it closes. Success offers
Pull and/or Merge when requested by the calling workflow, followed by Pop and
Apply only when the stash ref changed. A successful no-change save still offers
requested Pull/Merge, but does not offer Pop/Apply for an existing older stash.
Failure/cancellation offers no post-action. The original Pull/Merge/unshelve icons
are used. Pop/Apply retain their existing latest-stash semantics, matching source.

RefLog express Switch's failure-to-Stash handoff requests Pull, as upstream
`PerformSwitch` does. Generic Stash Save does not request it. Each save command
opens its own options window so a caller cannot replace another window's draft or
follow-up intent. Closing the progress sheet closes its owning options window;
post-actions close both before opening the destination dialog. Success/failure
callbacks refresh RefLog, Commit, Status and repository Log views.

The untracked warning has explicit pending state. Duplicate saves cannot open
another warning. Abort clears that state; Continue dispatches the captured options
once. A delayed warning response after the window closes cannot save. Closing
is blocked while warning/progress is attached or active. App Store progress
validates the retained repository security-scope lease. Core forwards an optional
cancellation token to the stash command; existing callers retain default behavior.

The [headless receiver](qa/stash-save-progress-native-2026-10-08.swift) and
[QA record](qa/stash-save-progress-2026-10-08.json) cover actual models/Git behavior,
not displayed acceptance. Captured Pull/Merge intent is passed to the post-action
callback, but native Pull/Merge destinations use their native workflows:
Merge now requests Stash Pop after success (see MERGE-PARITY.md); Pull's
subsequent Pop/Push flags now propagate through its owned progress (see PULL-PARITY.md). Live streaming,
active-process interruption, physical sheet/window/close/factory routing, warning
suppression persistence, signed invocation and broader application parity remain
pending. Existing screenshots show the options, not the new progress sheet.

Stash Apply/Pop now checks the retained security-scope lease before mutation in
App Store builds. Signed invocation/permission acceptance remains pending.

## Apply/Pop result model and remembered answers

The native controller now owns a separate testable result model. It retains the
selected Apply reference and repository lease, executes only once, refreshes
repository views after either Git outcome, and releases its result before the
Working Tree handoff. An answer callback can persist/open/close only once;
callbacks after invalidation cannot write preferences or open another window.

Default Pop success/conflict questions use independent native Bool preferences
StashPop.ShowChanges and StashPop.ShowConflictChanges. A remembered Yes or No
from fresh preferences skips that question after the actual operation. Apply
always asks and never offers suppression, including when Pop answers are saved.
Normal command errors acknowledge an error sheet without a status handoff or
preference write. Conflict output is still verified against actual unmerged
entries by Core; conflict Pop retains the stash.

The controller/model also accept the source showChanges modes: Pop 0 is silent
on clean success but asks on conflict; Pop >1 shows an OK notice; Apply 0 shows
an OK notice and nonzero asks. Existing menu/follow-up callers continue to use
default 1. Rebase automatic-stash integration is still pending; accepting its
mode here does not establish that caller's completion workflow. System progress
remains non-interruptible here, as the audited source's Git Run is synchronous
and does not consult its system-progress cancellation state. AutoCloseGitProgress
and Retry are not applied to these source result questions.

The spinner window blocks normal close and application Quit while running or
awaiting acknowledgement, including errors. Questions explicitly default to Yes.
Missing presentation chooses No through the model. The actual native
sheet/default focus/closure timing, missing-window ownership and end-to-end factory handoff still require
physical acceptance.

[Apply/Pop QA](qa/stash-restore-2026-10-08.json) records four-Git actual restore/drop,
conflict retention and selected older Apply, fresh-preference remembered answers,
a once-only callback into the real Status model, result modes, delayed/duplicate
guards and owned hidden-controller close/Quit guards. Existing screenshots predate
this model refactor; no new displayed window or screenshot is claimed.
