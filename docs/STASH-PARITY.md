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

- Displayed progress/sheet/cancellation acceptance and signed deployment. Apply/Pop use the source system-spinner workflow; a live output pane is not provided upstream.
- RefLog now provides native list, selected Apply, inspection and guarded Drop/Clear.
  Broader deletion/recovery QA remains pending. The pinned source does not offer
  selected Pop or branch-from-stash in this menu; they are not parity requirements.
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
default 1. Rebase now supplies mode 0 for automatic restoration and mode 1 for manually
requested restoration, as described below. Upstream Git Run is synchronous
and does not consult its system-progress cancellation state; native cancellation
is an explicit macOS adaptation. AutoCloseGitProgress
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


## Options/progress lifetime follow-up (October 11, 2026)

Forcibly closing standalone Save now invalidates/cancels its progress, detaches
and closes the owned sheet, and suppresses late results/post-actions. Private
controller preferences propagate to progress auto-close and warning suppression;
production defaults remain standard. This closes a cleanup gap found during
Synchronization Shift Save review. Closing Synchronization itself leaves the
standalone options window alive. The expanded Synchronization receiver covers
these real controller lifetimes, a captured message and a completed Apply
post-action callback. It does not drive the production workspace Apply factory
or establish displayed/signed acceptance.

At code checkpoint `e57e137`, all ten Synchronization groups and the existing
Stash Save model checks pass on both system and packaged engines. Both unsigned
builds, bundle audits, inventory and website checks pass. The backend's before/
after `refs/stash` reads still need cancellation-token propagation and separate
process-reaping checks; this phase checks the blocked main stash command only.
See [verification and limits](qa/synchronization-stash-lifecycle-2026-10-11.json).


## Stash reference-read cancellation follow-up (October 11, 2026)

Stash Save now passes its cancellation token into both before/after
`refs/stash` inspections and checks cancellation after each optional read.
An absent stash still permits Save, while cancellation is no longer swallowed
by `try?` or reported as successful completion. Cancellation before the write
preserves the working file/index and stash reference. Cancellation during final
inspection preserves any stash already created; it does not undo that write.

A controlled wrapper stalls each reference-read phase around a real Git save.
Core checks verify process reaping, preserved HEAD, untouched pre-save work and
retained post-save stash content. Native checks force-close options during the
first read and ordinarily cancel progress during the second. Closed options
suppress late replies; ordinary post-save cancellation shows Cancelled, offers
no completion actions and closes cleanly while retaining the created stash.
This addresses the reference-read gap recorded by the preceding lifecycle
checkpoint. Broader UI/physical/signed acceptance remains separate.

Focused checks passed on system Git 2.50.1, Git 2.39.5 and packaged Git
2.55.0; native Stash checks passed on system and packaged Git. Both unsigned
builds and bundle audits passed. See [verification scope and limits](qa/stash-reference-cancellation-2026-10-11.json).

## Replay stash and Apply/Pop ownership (October 12, 2026)

The replay family now checks tracked index/worktree changes before Start.
Rebase honors Git's effective `rebase.autostash` Boolean; Cherry Pick always
asks Stash/Abort even when that setting is enabled. Save excludes untracked and
ignored files and precedes the client Pre-rebase hook. Cherry Pick omits that
hook. Declining the question leaves the repository unchanged. A hook failure
retains the saved draft and allows restoration when leaving the window.

Done, successful Abort and completion commands first restore the saved changes:
automatic mode supplies Pop mode 0 (clean success is silent; conflicts ask),
manual mode asks Yes/No and supplies mode 1 after Yes. No retains the stash.
Restart/new replay intent also resolves the previous pending save first.
The native Rebase controller owns and awaits its Pop sheet before closing or
launching the destination. Ownership is in memory, matching upstream's
`m_bStashed`; recovery across process termination remains unimplemented. This
is not a lock against concurrent external stash writers: latest Pop semantics
match upstream. Active replay with an owned stash must use Abort/Done before
ordinary close.

Apply/Pop retain the source spinner and result questions, with a native Cancel
control. Cancel honors ConfirmKillProcess, defaults its confirmation to No,
terminates the owned process group, and waits for the operation to settle.
A cancelled operation reports retained effects rather than claiming rollback.
Forced owner closure ends only its alerts and cancels work; retired completions
cannot refresh views, save answers or open another window. Quit remains blocked
until owned restore work settles. Core also passes cancellation through selected
reference resolution and conflict-status inspection. These source comparisons
do not establish displayed or signed acceptance; batch validation is recorded
separately after execution.

This batch passed seven focused Core checks and grouped Stash/replay plus client
hook checks with system and packaged Git. A native acknowledgement/close race
was found and repaired; affected replay checks then passed again, including
existing immediate completion routes when there is no pending stash. All owned
receivers were reaped. See [actual results and limits](qa/stash-replay-batch-2026-10-12.json).
Restoration now re-reads effective `rebase.autostash`; see the October 14 checkpoint below. Mid-session configuration changes no longer use the Save-time choice. Hosted CI still fails its separate LFS native
selection assertion; these focused passes do not establish a green full run.

## Effective restoration policy — October 14, 2026

Rebase Done/Abort/completion now follows RebaseDlg::FinishRebase's fresh
rebase.autostash read. Enabling it after Save skips the restore question and uses
Pop mode 0; disabling it asks Yes/No and uses mode 1 after Yes. Cherry Pick never
uses this automatic policy. No retains the stash but clears the once-only session
flag, as source does. A failed/cancelled configuration read cannot clear the pending
stash or launch a completion action. Forced owner closure cancels this read;
independent accounting blocks Quit until the restoration worker settles.

The connected transport-hook/replay batch includes original manual/automatic
paths and both configuration flips with actual saved changes, older stash retention
and completion routes. Eight focused Core checks and six grouped native receivers
passed using system and bundled Git, with owned receivers reaped. See
[results and limits](qa/sync-replay-hooks-2026-10-14.json). Physical and signed restore
sheets, crash recovery and full replay parity remain open.

The connected [local command progress family](LOCAL-COMMAND-PROGRESS-PARITY.md)
adds live Reset/Switch/Stash output, shared native log styling/copy controls,
bounded presentation, independent ownership and once-only kill questions.

## Command entry and warning ownership — October 18, 2026

Source `stashsave`, `stashapply`, `stashpop` and `stashlist` now enter the native
Save, Restore and stash RefLog workflows. Save's `msg` preset remains editable;
repeated entry preserves its command-owned draft. Apply/Pop retain latest-stash
semantics and source result questions. Existing source icons and options remain.
All these workspace consumers pass captured preferences rather than falling back
to global preferences. Busy stash operations refuse competing launches and Save
acceptance within that workspace; this does not coordinate unrelated processes.
Untracked-warning responses are matched by request identity, preventing a reply
from a cancelled warning accepting a later snapshot. See
[command entry](COMMAND-LINE.md#merge-and-stash-command-entry) and
[batch evidence](qa/integration-commands-2026-10-18.json) for actual Git validation
and remaining platform limits.

## Save command receipt and owned follow-ups — October 19, 2026

Pinned `CAppUtils::StashSave` (`AppUtils.cpp:106–158`) constructs a generic
`CProgressDlg`, not Apply/Pop's system-progress/result-question workflow. Save
retains the message, Include Untracked/All exclusivity and existing warning,
identity preflight, source icons and post-action order. Successful Save offers
configured Pull/Merge first and Pop/Apply only when the stash reference changed.
No Save Retry menu is introduced.

Core emits the actual executable/argv immediately before `stash push`, with Git's
own pathspec semantics retained. A separate command receipt follows actual process
and output drain, before the final `refs/stash` read. Native output uses captured
preferences/pasteboard, styled completion range, actual timing/date and retained
100 percent. Metadata failure or cancellation keeps its own diagnostic boundary;
it cannot rewrite an already successful Git process receipt. Follow-up actions
still require a successful, fully settled workflow. Optional display quoting is
POSIX syntax for macOS; it is never executed.

Start reserves per-instance and Quit ownership before scheduling. Invalidation
cancels but retains actual worker/read ownership. Result and parent callbacks wait
for real work, owned questions and native sheet detachment. No/Yes answers are
one-shot and matched to the active owner; a retired, duplicate or late Yes cannot
cancel settled work or open a child. Intended result closure snapshots appearance
and opacity before dispatching Pull, Merge, Pop or Apply, retaining the original
preferences and repository access. Forced closure drops a pending handoff.
Restore's View Changes similarly carries its captured presentation into Working
Tree. Working Tree owners with different preference instances retain separate
drafts; repository refresh/rename notices reach every owner for that root.

[Grouped evidence](qa/stash-export-progress-family-2026-10-19.json) records the
actual checks after the implementation freeze. Complete physical keyboard/menu/
VoiceOver and visual parity, unrelated external stash writers, crash recovery,
full source geometry, signed grants/Finder/App Store acceptance and the whole port
remain unverified. Apply/Pop's source spinner/questions are not converted to a
Save-style footer.
