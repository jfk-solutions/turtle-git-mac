# Reset parity

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`, ResetDlg.cpp/.h,
IDD_RESET, CChooseVersion, CAppUtils::GitReset and ResolveProgressCommand.

## Native layout and entry points

Reset now has a dedicated native window rather than the generic Log action sheet.
It retains Current branch, the Reset active branch group with Branch/Tag/Commit
rows, reference/commit browse buttons, the Reset Type group with all three
upstream descriptions, Show modified files in working tree, and OK/Cancel/Help.
The nineteen resource controls are mapped; the current branch label and read-only
value share a native text row. Mixed is initially selected. Bare repositories use
Soft and disable Mixed, Hard and the working-tree button, matching ResetDlg.
Original reset artwork is used by the app menu and Log context command. Light
and dark native captures are site/assets/reset.png and reset-dark.png, both
1380 × 850 pixels. Reset is an app/Log command, not an added Finder shell menu.

Log captures the selected revision and opens this window. Submodule side resolution
opens it with the chosen index-stage commit when the initialized child checkout
differs. The full parent conflict selection is revalidated after successful Reset,
then resolution resumes. Cancelling Reset leaves the conflict pending. Repeated
Reset requests retain the existing window and append required completion callbacks.
The app keeps the captured repository access lease alive for this operation.

Commit browse now owns the full native Log dialog in single-commit selection
mode, anchored at the typed commit revision, with the graph, filters and details.
Its Working Tree row is suppressed. OK returns a full selected hash; Cancel
preserves the draft. Reset/apply/modified-files/parent close/Quit wait until the
picker releases. Branch browse now owns the native all-reference namespace tree and metadata
list, including filters, merged/unmerged selection and canonical handoff with a
fresh catalog and active-revision focus. See [reference browser parity](REFERENCE-BROWSER-PARITY.md);
full menus, other chooser consumers and history-combo parity remain pending. Show modified files now opens an
owned Changed Files comparison sheet of HEAD against the working tree, matching
ResetDlg::OnBnClickedShowModifiedFiles. This range is independent of the selected
Reset revision and leaves that selection intact. Reset/Apply/Cancel and parent
close stay locked until the child closes. Quit also waits while the preview, Reset
operation, confirmation or result acknowledgement remains active. The comparison keeps ordinary Log, file
history, submodule and file-diff actions; duplicate requests reuse the modal lock.
Frame position is saved. Help opens the upstream reset manual.

## Git behavior and safeguards

The chosen revision is verified as a commit using --end-of-options and captured
as a full hash. Reset runs against that hash, avoiding later ref changes. Before
execution both HEAD and its symbolic branch are compared with the captured plan;
a changed branch at the same hash also requires a new review. Soft leaves index
and working contents; Mixed resets the index and preserves working contents;
Hard resets both. Bare repositories reject non-Soft operations in the backend.
Detached reset moves HEAD without moving the former branch.

Hard adds a native warning describing tracked replacements and potentially removed
obstructing untracked files; Cancel is the default. This additional confirmation
is a deliberate macOS safeguard. Native warning/cancellation still need verification:
interaction with the existing dark preview repeatedly reported no available window
or invalid element, despite subsequent inspection showing its Reset window. It was
not restarted to treat observation failure as completion. Hard execution is covered
in disposable core tests, not claimed as natively exercised.

## Verification

The full suite passes 153 tests. Three Reset integration tests cover exact mode
HEAD/index/worktree effects, ORIG_HEAD, unchanged untracked files/tags, invalid
and non-commit revision rejection, stale HEAD/branch rejection, bare Soft-only
behavior and detached HEAD. Conflict tests now additionally verify executable
modes, exact gitlink sides, uninitialized checkout preservation, initialized mismatch
rejection and matching checkout resolution. Finder discovery tests confirm that
an exact conflicted submodule selection resolves in its parent, while ordinary
commands and files inside the child still use the child repository.

Native /private/tmp/TurtleGitResetQA Mixed reset to HEAD^ moved HEAD to the target,
made the index equal its tree, retained ORIG_HEAD and preserved every working file.
Light and dark layouts were inspected and captured. Post-close parent restoration
could not be observed and is not claimed.

Native /private/tmp/TurtleGitSubmoduleResetQA selected Resolve using theirs through
a Finder-style URL for the initialized child. The first check exposed parent/child
routing; the corrected build opened the question and Reset with the exact stage-3
commit. Choosing Soft then OK resumed Resolve and displayed one resolved file.
Git verification proved the child HEAD and parent gitlink matched the chosen commit,
while parent HEAD/refs/unrelated index, child index and all working files remained
identical to the captured baseline. Signed Finder activation is not proven by this
Debug URL dispatch.

## Remaining parity

Full upstream ref/log chooser and FileDiffDlg, complete progress controls and physical cancellation/post-action acceptance,
native Hard warning/Cancel and error recovery, bare native layout, keyboard focus,
Help, saved position, Log handoff, parent restoration and signed sandbox runtime
remain pending. Full submodule Base/Mine/Theirs chooser remains unported. Delete/modify conflicts
now have a native window with separate gaps recorded in DELETE-CONFLICT-PARITY.md. Reset and Resolve remain partial.


## Owned result and command follow-ups

Production Reset now opens a separate native progress sheet with captured immutable
ResetPlan, output, semantic completion colors and original action icons. Failure
retains Retry. Successful Hard reset offers Submodule Update when the working tree
has .gitmodules (the source HasSubmodules gate, even without index gitlinks), then active-bisect Good/Bad/Skip/Reset actions in
source order, then Clean. Soft/Mixed offer only applicable bisect actions. Clean,
Submodule Update and bisect dispatch open the existing native flows after releasing
the result, once only. These operations are not executed by constructing their menu.

AutoCloseGitProgress applies: manual retains all results; no-options closes successful
Soft/Mixed without actions but retains Hard/Clean and bisect/submodule results;
no-errors closes all successful results. Failures stay open. ConfirmKillProcess
uses the native Yes/No cancellation question with Yes default. No keeps running;
Yes stops owned Git/helper processes. Retry creates a fresh token and reuses the
captured plan. Its HEAD/branch check stays active: changed HEAD or symbolic branch
requires closing the result and reviewing the options again, rather than silently
resetting a different branch. Cancellation may leave actual Git effects, which are
not rolled back. Result notifications refresh repository views after every attempt.

The native Hard warning now has an explicit pending state and No/Yes callback;
inputs and duplicate submissions remain locked while it is open. No leaves the
repository unchanged. Success notifications for callers, including submodule
Resolve continuation, occur once after result acknowledgement. Failed Close restores
the options dialog. The no-presenter headless compatibility path retains immediate
completion. Missing production presentation cancels and releases its owned result.

[Progress QA](qa/reset-progress-2026-10-08.json) records real mode effects, close
policies, native confirmation/acknowledgement model callbacks, stale branch retry
rejection/recovery, ordered submodule/bisect actions, and owned No/Yes cancellation
with fresh Retry. Hidden progress hosting does not establish displayed interaction.
Streaming/full progress controls, libgit2 variants, metadata-query error recovery,
physical nested sheets/defaults/keyboard/menus/close/focus/themes/accessibility,
actual follow-up controller/Resolve handoff and signed sandbox/Finder/App Store
acceptance remain pending. Existing screenshots predate the owned result.

## Modified-files comparison follow-up

[Owned comparison QA](qa/reset-modified-files-2026-10-09.json) covers the real
HEAD-to-working-tree file list with staged and unstaged changes, staged additions
and deletions, and a Unicode/tab/newline path. Untracked files and differences
existing only against the selected older Reset target are excluded. Hidden native
controllers verify duplicate/reset/apply/close gates, child release/reopen, stale
close callbacks, rejected presentation, bare/busy guards, Quit locking and release,
forced parent cleanup
and unchanged HEAD, staged tree, configuration and working contents. The test
injects presentation without displaying a sheet; actual sheet interaction,
keyboard/default buttons, focus restoration, visual layout and signed sandbox
behavior still require acceptance. Existing Reset screenshots predate this route.

## Reset initial focus and commit Log picker

The selected Reset type receives native first-responder focus once after initial
metadata loading; bare repositories focus Soft. Caller-provided Soft/Mixed/Hard
modes are preserved outside bare repositories. Ordinary updates do not repeat
the handoff, and closed controllers invalidate pending focus. This follows
ResetDlg::OnInitDialog, whose InitChooseVersion() does not request combo focus.

[Picker QA](qa/reset-picker-2026-10-09.json) records hidden native focus and real
Log-controller selection/cancellation, ancestry and child lifecycle checks with
both Git engines. Single-commit Log pickers now enforce one row in NSTableView;
ordinary and explicit multiple-selection Log modes retain multiple selection.
Presentation is injected, so physical sheet interaction, keyboard navigation,
focus after closing a child, visual comparison and signed acceptance remain
unverified. Full BrowseRefs and ChooseVersion behavior is still partial.

The injected presenters release keyboard focus from the disabled parent, without
ordering either window. A retained-parent-focus diagnostic emitted SwiftUI
AttributeGraph cycles; clearing parent focus removed them from the full Log
picker receiver with identical source and assertions. This supports a synthetic
presentation cause, not physical sheet acceptance. Initial focus bookkeeping is
non-published and the radio state retains its original binding, avoiding needless
view publications.

## Reset reference browser

[Reference browser QA](qa/reference-browser-2026-10-09.json) records the native
namespace/table and Reset branch/tag/remote/custom-ref handoff checkpoint. Private
hidden hosts exercise nested/merge/text filters, original context icons, owned
Reflog, refreshed catalogs, revision input focus, draft/cancel/rejected/stale/close
and competing-route gates. Physical sheet interaction, visual layout comparison
and complete BrowseRefs/ChooseVersion behavior remain pending.

The commit-revision row now uses the shared [editable session combo](VERSION-COMBO-PARITY.md),
including programmatic custom choices, exact native Git token identity and
disabled/retired/focus guards. Physical popup and complete dialog acceptance remain open.

The connected [local command progress family](LOCAL-COMMAND-PROGRESS-PARITY.md)
adds live Reset/Switch/Stash output, shared native log styling/copy controls,
bounded presentation, independent ownership and once-only kill questions.

## Connected chooser, confirmation and result ownership — October 15, 2026

Pinned `ResetDlg.cpp` and `IDD_RESET` retain the source groups and order:
current branch, Branch/Tag/Commit target, Soft/Mixed/Hard, full-width modified
files action and OK/Cancel/Help. The native host now constrains vertical resize,
matching the source's horizontal resize policy. It remains a native adaptation,
not a complete visual parity certification.

Reset now passes its preference domain into the shared chooser, its From/To
modified-files comparison and its owned Log. The chooser honors private Fetch
HEAD visibility, local-first reference ordering and reversed tag ordering. Log
receives the entered revision before its view is created, uses the shared
production command configuration and inherits the owner's appearance and opacity.
Selected commits enter the editable revision session history.

Reference and commit selections retain the initiating target, branch, tag, commit
and reset mode. A result cannot overwrite changed inputs, consume a newer picker
or apply before the owned child/sheet has retired. Cancel and refused presentation
release ownership; forced parent close invalidates pending callbacks. Hard reset
uses a distinct confirmation identity and the reviewed input snapshot; an old
Yes callback cannot approve a newer question. The actual alert-to-progress
transition waits for sheet detachment. Refusing progress presentation releases
the model and never starts Reset.

Initial branch/bare metadata, shared chooser references and reset preparation are
cancellable and retain global Quit/access ownership until the reads settle, even
after forced close. Window Close cancels reads and closes after both readers
settle; the explicit Cancel control stops a read while retaining the dialog.
Retired Reset models cannot reopen pickers/comparisons or initiate Reset. The
legacy no-progress caller now retains mutation ownership and publishes completion
only after clearing its busy state. Real reset execution still uses the pinned
Core plan and changed-HEAD guard.

The dated QA record identifies local native coverage and any failures/repairs.
Complete physical keyboard/menu/VoiceOver behavior, all dialog layout/color
comparisons, signed Finder invocation and App Store sandbox acceptance remain
open. Earlier records remain historical evidence for their stated scope.

## Reset command progress and owned recovery — October 19, 2026

The connected source comparison is `AppUtils.cpp::Reset` and its post-command
callback, `ProgressDlg.cpp::RunCmdList/OnProgressUpdateUI` and `IDD_GITPROGRESS`.
The native model captures the actual Reset invocation after read-only validation
and immediately before execution. Its quoted executable/arguments enter the log
before process output; Git still executes an argument array. This uses the Core
command receipt rather than a second native reconstruction of Reset flags.

Completion now retains the shared styled output, a distinct success/failure
footer range, result current-work label and 100 percent bar. Elapsed time/date are
captured when the command finishes, before bisect metadata is read. Disabling
`ShowGitexeTimings` leaves the result status. An actual cancelled Git result keeps
its exit code; cancellation without a process result uses the explicit native
User cancelled fallback, and a failure without an exit code uses Operation failed.
The original Git output remains separate from these presentation records.

Start and Retry synchronously reserve actual pending work before scheduling a
Task. Model invalidation cancels its token and refuses publication while retaining
Busy/Quit/access ownership until the real work returns. Kill-question answers
remain one-shot, wait for native sheet detachment and reject old/Quit responses.
Post-actions and automatic close wait for worker and child drain; forced closure
does not run a pending handoff. Child Submodule Update, Clean and Bisect actions
retain the originating preference domain, repository grant and captured
appearance/opacity without retaining the closed progress window.

Successful source action order remains Hard-reset Submodule Update when applicable,
the active Bisect Good/Bad/Skip/Reset choices, then Hard-reset Clean. A failed
command offers Retry. Bisect-state reads now receive the attempt cancellation
token. Their failures append a diagnostic without relabelling a successful Reset
command as a Git failure. Retry owns a fresh output/completion record; it retains
the original plan and the existing changed-HEAD validation rather than silently
resetting a newly moved target.

[Grouped evidence](qa/switch-reset-progress-family-2026-10-19.json) will identify
the actual validation scope and repairs. This text adds no passing-check claim
before that record. Physical controls/defaults/VoiceOver, all reset/recovery
combinations, signed Finder/sandbox grants, source visual equivalence and complete
application parity remain open. The source alternative libgit2 progress path is
not certified by this native CLI continuation.

Clean and Bisect child caches retain independent idle windows for distinct
preference domains. Their close callbacks remove only the exact cached controller
they own, preserving another live instance. A running Bisect operation for the
same repository still excludes a new competing operation even across preference
domains. Clean and Submodule Update carry the captured appearance/opacity into
their owned progress windows as well as the initial options window. These routing
details preserve the Reset-origin presentation through the actual child workflow,
without claiming physical or signed acceptance.


## Native source form control continuation

[The connected form family](SOURCE-FORM-CONTROLS-PARITY.md) records reference
keyboard/focus and bounded captions, Push F5 refresh and Synchronization native
split controls, with owned state and remaining acceptance kept explicit.
