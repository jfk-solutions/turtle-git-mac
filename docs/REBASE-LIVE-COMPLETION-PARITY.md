# Live replay progress and completion

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`RebaseDlg.cpp::UpdateProgress` at 1920–1972, `FinishRebase` at 1132–1190,
`OnRebaseUpdateUI` at 2497–2514 and the `IDD_REBASE` source list policy.
This is one connected family of the partial native Rebase/Cherry Pick port.

## Source behavior

The progress bar counts handled source commits, rather than internal Git commands.
The current commit is bold and brought into view; earlier handled rows are dimmed.
The ordinary current row contributes its one-based position to the status caption
and the preceding position to the handled count. Finish accounts for the final
commit. Repeated selections are separate occurrences even when their hashes match.

Successful ordinary Rebase selects the execution log and removes the earlier
file/message tabs. Cherry Pick returns before that source cleanup. An automatic
Fetch→Rebase sets Auto End and posts Done after successful completion; it does not
choose the Show Log post-action. Done also settles the existing stash restoration.
Manual completion keeps the configured post-operation split control.

The source explicitly enables Show log in the Rebase list and retains it for
completed/current/pending source rows. An unnamed commit does not require Shift
to expose that command.

## Native implementation

Replay mutation scopes publish typed progress receipts from the owned command
drain loop. They read the sequencer's source identities and completed commands;
they do not interpret a localized `Rebasing (n/m)` diagnostic as a logical count.
Labels, resets, merge scaffolding, branch-reference updates and owned empty-message
checkpoints do not inflate the source-row total. Receipt actions remain original
actions; completed manual Skip display bookkeeping retains its separate role.

The observer performs no Git subprocess read or repository mutation. It bounds
payload sizes, checks coherent metadata/HEAD bytes and directory identity, and
uses metadata signatures to avoid rereading an unchanged plan on idle output
polls. Replacement, changed immutable identities, cancellation and retirement
cannot become fresh progress. Successful terminal receipts follow the actual
command result and inactive session, while Abort is excluded.

The native owner validates operation, repository window, epoch, session, source
occurrences and monotonic logical position before publication. A final receipt
mailbox settles delivery before late MainActor callbacks are invalidated. Progress
changes row styling and an occurrence-specific scroll request without redirecting
the user's selection or changing actions. The footer and existing shared Dock
progress use the same logical handled/total values. Unknown/unowned sessions keep
their available stopped-state information rather than an invented live count.

Successful ordinary Rebase retains only the Progress tab. A captured automatic
Fetch→Rebase success requests Finish once, after its replay worker releases busy
ownership, and uses the existing owned stash restoration and close workflow.
Cherry Pick, manual mode, failure, cancellation, unknown external completion and
retired/replaced owners cannot approve that automatic handoff. The explicit Abort
close behavior remains its separate existing path.

Rebase's shared menu policy now exposes Show log for ordinary eligible rows, with
the original icon and captured source commit target. Existing mutation-busy and
child/modal guards remain in force; this family does not certify every source
menu during a running Git command.

## Validation and remaining work

The [grouped checkpoint](qa/rebase-progress-completion-2026-10-25.json) records
24 distinct focused Core methods cumulatively passing, one successful Debug app
build, and all six native scenario/engine pairs passing with system Git 2.54.0
and bundled Git 2.55.0. Two test compilation repairs and three scenario-fixture
repairs are recorded; only failed checks were repeated. The completed Skip
regression explicitly changes prior-row presentation during real live progress;
it does not prove an actual Git `--skip` path. Stash restoration uses real Git
and the existing native completion callback, held and released to check ownership.

All eight attempted native receivers were reaped and independently absent.
The cached receiver reused app objects and only recompiled changed fixtures.
No full Core suite, physical visual acceptance or current hosted CI pass is
claimed by this focused checkpoint.

Physical scroll/focus/VoiceOver, full source layout and contrast, signed installed
replay, minimum supported macOS, physical Intel, all custom/external plans and
complete hosted integration remain open. Completion Send Mail retains its separate
Format Patch/output-directory adaptation. Full Rebase, Cherry Pick and application
parity are not certified by this family.
