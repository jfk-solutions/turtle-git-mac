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

The browse controls reuse the current reference and commit choosers; their full
upstream tree/search/log parity remains pending. Show modified files opens the
native Working Tree dialog rather than upstream FileDiffDlg; full diff-list parity
is still required. Frame position is saved. Help opens the upstream reset manual.

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
