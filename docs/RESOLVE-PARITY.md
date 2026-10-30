# Resolve parity

Baseline: upstream `7338078f8ddd924b8cddee35f512f2286072136d`, ResolveDlg,
ResolveCommand, IDD_RESOLVE and shared status-list resolution actions.

## Native dialog and operations

The checked conflict list includes Path, Extension and Status, followed by the
three-state Select/deselect all checkbox, commit reminder and OK/Cancel/Help.
All six resource controls have native mappings. Highlight selection and checked
selection are independent. Mixed and checked select-all clear the checks; unchecked
select-all checks every row. Frame position is saved and F5 refreshes the list.
The original menuresolve.ico is bundled with source/hash provenance.

OK stages only checked paths using their current working contents. Context menus
also offer Resolved, Resolve using mine and Resolve using theirs. Context actions
ask Yes/No before execution; normal OK follows the upstream checked-list flow.
Success now reports the resolved count in the owned progress view and offers Commit. No operation automatically
commits or continues a merge, rebase or cherry-pick.

Mine uses actual index stage 2 and theirs uses stage 3. During rebase the menu
labels explain these as the branch being rebased onto and commit being replayed.
A missing selected stage means deletion. Text, binary and symbolic-link sides use
Git checkout-index followed by add; current contents use add -f. Captured stages
are validated for every checked item before mutation. Literal path arguments
support leading dashes, Unicode and newlines. Paths cannot enter Git administrative
directories, escape the working tree through parent links or enter nested repos.
Later per-item Git errors can leave earlier resolutions applied; batches are not
transactional. Errors refresh parent models and retain the normal dialog.

Gitlink sides can update the index when their existing checkout matches the chosen
commit, or the submodule is uninitialized. A differing initialized checkout is
handled through the native Reset window, after which resolution revalidates and
resumes. Exact side pointers and mismatch rejection have dedicated tests; a native
Soft-reset/resolution handoff preserved child index/workfiles and unrelated parent
changes. The native Base/Mine/Theirs chooser is now implemented in part; remaining edge
cases are tracked in SUBMODULE-CONFLICT-PARITY.md. See also RESET-PARITY.md.

Finder exposes normal Resolve when cached conflicts fall within the selection.
Commit, Working Tree and workspace conflict menus dispatch the side choices.
Signed Finder activation and full selection/menu conditions remain unverified.

## Verification

The full suite passed 153 tests. Ten conflict tests cover current, mine/theirs,
binary, modify/delete, scoped selections, stale snapshots, rebase stage mapping,
symlinks, executable modes, initialized/uninitialized gitlinks and Finder scope
boundaries including conflicted submodule ownership. Original icon decoding also passed. The
final native layout and checkbox changes compile successfully.

Native QA in /private/tmp/TurtleGitResolveQA verified two initial checked rows,
partial/mixed checks, mixed-to-clear, clear-to-all and disabled OK with no checks.
OK with only README.md checked staged its manually resolved contents; the other
path stayed unmerged. HEAD, refs, every working file and all unrelated index
entries were compared to the captured baseline and remained identical. The result
sheet reported one resolved file and offered Commit. Context Resolved opened the
Yes/No question; No returned to the dialog. No and Cancel preserved HEAD, index,
status and every working file. After Cancel the window observation failed while
the app inventory still showed the preview running; parent restoration is not
claimed. The actual native capture is site/assets/resolve.png (1560 × 964).

## Remaining parity

Full three-way merge integration, remaining submodule chooser cases, source
status-list action-mask corner cases and column menus, temporary merge artifact
ownership and cleanup, remaining batch/error variants, branch identity
labels, broader native side-choice execution, complete
refresh/retry and Commit handoff acceptance, dark-mode/keyboard/Help QA, parent restoration,
signed Finder and sandbox runtime remain pending. Double-click now opens the native delete/modify chooser for a single ordinary
missing-side conflict (see DELETE-CONFLICT-PARITY.md), and the native submodule
chooser for gitlink conflicts (see SUBMODULE-CONFLICT-PARITY.md). Ordinary UTF-8 text conflicts now open the partial native three-pane editor;
see TEXT-MERGE-PARITY.md for implementation and verification gaps. All Resolve
workflow records remain partial; no complete dialog or App Store parity is claimed.

Submodule deletion now offers native Delete/Abort after failed Git removal.
Delete uses recoverable macOS Trash; Abort and stale-confirmation preservation
are tested. The latest full suite passed 167 tests.

The shared native select-all control now reads the live checked count at activation
and respects the disabled busy state. The hidden native receiver checks checked,
off and mixed activations against two real conflicts with both Apple and bundled
Git, including consecutive activations and disabled activation.
Selection-only checks preserve the raw index; they do not establish additional
resolution operation or physical input coverage. See
[shared checkbox QA](qa/lfs-tristate-2026-10-08.json).

## Resolve progress and ownership batch — 14 October 2026

Checked OK and quick/current/Mine/Theirs resolution now use the same owned
progress view, with streamed Git output and resolved-path notifications even
when Git is silent. The visible log uses the shared bounded UTF-8/CR parser and
native colored, selectable/copyable output; parent callbacks retain original
command output. The completed-path count and current path update during a batch.
There is no automatic commit, replay Continue or rollback of earlier resolutions.

Cancellation is carried through initial/all-item validation, every owned Git
command, per-item boundaries, submodule reset-target reads and the Delete/Abort
confirmation before a recoverable Trash move. Cancel optionally uses the captured
Confirm Kill Process preference. A settled command cannot be cancelled by a late
answer; duplicate sheet replies cannot resume twice. Cancel and errors refresh
the actual conflict list, retaining earlier resolutions and remaining checks.
Back returns to the checked list after failure/context actions. Success offers
Commit and closes Resolve before invoking its caller. The source auto-close
policy is captured per attempt; Commit counts as an available post-action.

Initial refresh and base comparison now own cancellable reads, repository access
and Quit counters through settlement. Base comparison validates captured stages
before and after the no-ext-diff/no-textconv read. Refresh requests during work
are coalesced. Retirement cancels owned work and settles its question once;
late rows, prompts, errors and handoffs cannot revive a retired Resolve owner.
Submodule Reset retries retain the captured stages and owner generation. Closing
a cancelled Reset returns Resolve to its list without applying a resolution.

Validation evidence is recorded in
[the Resolve progress QA record](qa/resolve-progress-2026-10-14.json).
Physical controls, full conflict-editor/menu parity, drag/drop, temporary merge
artifacts and signed Finder/App Store execution remain open. This is a connected
workflow batch, not complete Resolve or whole-app certification.

Single ordinary Compare with base now opens the full native two-pane editor with
captured stage-1 and editable working contents. Multiple selections retain the
unified output sheet. Index-stale and working-byte-stale saves are rejected; see
[the conflict review family](DELETE-CONFLICT-PARITY.md).

## Shared conflict identity family — October 15, 2026

The [shared conflict identity reader](CONFLICT-IDENTITIES.md) supplies captured
operation/branch captions and the default-on guessing policy. Text/image panes,
delete/modify and submodule sides and external merge-tool arguments share the
same stage mapping. The Advanced disable-guessing setting now has a runtime
consumer. Existing source-control mappings and complete-dialog acceptance remain
partial; earlier generic-label gaps are superseded within this documented scope.

[Grouped validation and visual review](qa/conflict-identities-2026-10-15.json)
record actual coverage and remaining limits; no dialog is newly certified.

## File drops, source keys and parent refresh — October 16, 2026

ResolveDlg::OnFileDropped and its 200 ms REFRESHTIMER now have a native file-URL
receiver. Files/folders must belong to the same worktree; nested repositories,
Git administrative paths and outside files are ignored. Existing scope ancestors
prevent duplicate child scope entries; dropping the root restores whole-repository
scope. A dropped conflict is checked again; directory drops recheck descendant
conflicts, preserving unrelated manual unchecks and highlighted rows. Newly
discovered conflict rows receive the source's default check on ordinary refresh.
Drops only read membership/status: they do not add/stage files or resolve them.

A drop during an existing status read queues behind it. Closely spaced providers
share a coalesced status read. URL/membership/status work retains the repository
grant and existing Resolve/Quit ownership until settlement. Cancel clears queued
providers; late cancelled/retired callbacks cannot publish scope, checks, rows or
errors. Busy resolution/progress, quick Resolve, questions and child editors
refuse drops. Native busy feedback identifies the drop read.

Window-scoped F5 and Control-Return (also Command-Return) now dispatch to the
existing refresh/checked resolution owners, with background, sheet, empty-check,
busy and retired refusal. The transient hidden F5 button is removed.

RefreshFileListAfterResolvingConflict now gates explicit parent status/Commit/
Resolve list refresh callbacks from text/image/delete/submodule/external tools
and Resolve completion. Source default true and exact DWORD == 1 semantics are
retained. Replay state, Log/repository notifications, the resolving window's own
result read, explicit F5 and independent filesystem observations remain active.
This setting does not freeze the repository or disable validation before writes.

Source references: ResolveDlg.cpp/.h, GitStatusListCtrl::ResetChecked,
AppUtils.cpp::StartExtMerge and Commands/ResolveCommand.cpp at the pinned source.
Missing dropped files are ignored by the native membership reader; dropping their
containing directory includes their indexed conflict rows. Physical Finder drag,
all source context menus, temporary merge artifacts and signed acceptance remain
open. This batch does not certify full Resolve or application parity.

Both Debug builds and all four native case/engine runs passed at the grouped
checkpoint, with no failed native cases or reruns. The provider-cancellation
refinement and Help were included in the second build before native verification.
All four owned receivers were reaped and independently absent. Native fixtures
use real local conflicts and injected held providers; physical drag/keyboard and
signed acceptance remain separate. [Batch evidence](qa/resolve-interaction-family-2026-10-16.json)
records exact effects, preference scope and retained progress assertions.

## Captured file-action menu family — October 16, 2026

The source Resolve status-list mask keeps conflict editing/resolution first, then
base/unified and two-file comparisons, history/Blame, editor/Open/Open With,
Explorer/Finder and clipboard groups. Resolve now connects those read-only
commands with original artwork and private context-icon preferences. Export,
Save revision, Add, Ignore and comparison marks remain excluded by the source
mask. Revert and eligible Delete are connected in the mutation continuation
below; remaining column-hit menus and physical default-item styling are separate
parity work. No complete context-menu claim is made.

A popup retains its ordered ConflictEntry stages and owner/list epoch. It can
invoke once; selection changes do not redirect it. Refresh/drop replacement,
resolution, retirement, modal children and busy state reject obsolete targets.
File handoffs re-read exact stages, and Open With revalidates after application
selection. Cancellation and forced closure settle the owned panel, refuse late
handoffs and retain Resolve/Quit accounting until the actual worker returns.
The repository lease survives preparation and application handoff.

Ordinary existing files offer editor/Open/Open With and eligible HEAD-pinned
Blame. Two ordinary files compare in captured display order. Missing work files
omit Open/Blame; Reveal finds their existing parent. A gitlink offers parent
file history and separate child-repository history, using the shared scoped
submodule reader. Unified diff captures Shift and exact no-ext-diff/no-textconv
base patch bytes, revalidates after reading and uses the owned native/external
unified viewer. Base comparison retains the existing stage-1 editable viewer.

The shared clipboard formatter now accepts conflict rows directly, retaining
literal names/order, directory extensions and Resolve's Path/Extension/Status
columns without creating ordinary status records. Copy all and native
Command-C/Shift-Command-C use the same one-use snapshot and preference guards.
Native text field editors keep their own clipboard handling.

Source reference: GitStatusListCtrl.cpp OnContextMenuList and command dispatch,
with ResolveDlg::OnInitDialog's mask, at the pinned upstream commit. Actual
receiving apps, Finder gestures, popup tracking/column hit-testing, signed grants
and full source-menu/visual/VoiceOver acceptance remain open.

Eight focused clipboard Core cases and all six grouped native case/engine runs
passed. Review then aligned the displayed Extension column with the shared source
formatter: leading dot for files, empty for gitlinks. Only the affected file-menu
cases were repeated, with both engines and a `module.ext` fixture; both passed.
All eight receivers were reaped and independently absent. Actual receiving apps,
physical popup/copy gestures and signed grants were not exercised.
[Batch evidence](qa/resolve-file-menu-2026-10-16.json) records builds, checks and
the source eligibility/mutation work still open.

## Revert and missing-file Delete — October 16, 2026

Resolve now connects the source Revert and missing-mark Delete commands to the
existing native operation owners. Revert obtains real porcelain rows from the
captured conflict stages, uses the HEAD diff's modified-file confirmation and
opens the shared Revert progress sheet. HEAD and stages are validated before
launch and the first execution. Retry reads fresh selected-path status while
keeping the original HEAD boundary and accepted working-file disposition policy.
The shared [Revert policy](REVERT-PARITY.md#captured-working-file-disposition-policy)
captures the master and renamed-file Trash switches independently. Prior actual
Trash receipts remain available; replacement contents bypassing Trash are not
promised recoverable. The source No-options auto-close and submodule post-action
are retained. Gitlink reversion changes the parent index, then offers the existing
submodule comparison workflow without changing its checkout automatically.

Delete is offered only when the captured selection mark is physically missing.
Its command retains the complete selected set, mark and Shift-permanent choice.
A native No-default confirmation precedes a fresh stage/missing-mark check. The
shared writer validates every selected path, moves existing files to Trash (or
permanently removes them for captured Shift) and only then installs a private
index with those selected entries removed. Ordinary existing conflicts do not
gain an unrestricted Delete command. Explicit paths, including punctuation and
Unicode, remain literal; unrelated index entries and HEAD remain independent.

The table tracks pointer/keyboard selection marks without consuming events. Its
monitor is scoped to the owning window and is explicitly removed on Close as
well as view dismantling. Pending questions/children retain Resolve/Quit ownership;
Close requests cancellation through the actual progress owner and forced retirement
settles the question/child once. Actual conflict rows refresh after success,
partial failure or cancellation; completed filesystem/index steps are retained.
Publishing mutation results invalidates older captured menus, including menus for
other still-conflicted paths; a fresh popup is required after the list changes.

Source: GitStatusListCtrl.cpp IDGITLC_REVERT, DeleteSelectedFiles and the popup
mask; RevertProgressCommand at the pinned source. Native Trash and confirmation
sheets adapt SHFileOperation. Remaining source action-mask corner cases, column
menus/hit testing, physical gestures, every submodule/partial-error combination
and signed Finder/App Store acceptance remain open.


[Grouped mutation evidence](qa/resolve-mutation-family-2026-10-16.json) records
11 passing focused Core tests and eight passing native case/engine checks:
mutation, retained file menus, drop/keyboard and resolution progress, each with
system and bundled Git. A real stale-popup failure led to invalidating menu
epochs after mutation refresh; its assertion remains. The retained missing-gitlink
menu expectation was updated for the new Delete command. Only affected/unpassed
cases continued. All ten receivers, including failures, were reaped and
independently absent. The native mutation runs emitted NSTableView reentrant
operation warnings; future SDK/physical table acceptance remains open.

## Exact conflict paths and native checks — October 18, 2026

The [connected Resolve/Rebase conflict family](CONFLICT-PATH-IDENTITY-PARITY.md)
now preserves distinct valid UTF-8 paths through stage grouping, row IDs,
checked/highlighted memory, refresh, captured menus and resolution validation.
The native binary checkbox follows the source highlighted-row rule. Shared
Git actions retain their existing mutation/cancellation and child lifetimes.
Physical/signed acceptance and broader invalid-path handling remain open.

## Resolve command modes and shared ownership — October 18, 2026

The primary `resolve` command accepts independent `silent` and `noquestion`
flags. Normal entry opens the existing checked conflict review and progress.
`silent` alone keeps the review but applies its accepted checked rows without a
progress panel, closes on success and reports failure for acknowledgment. Context
Mine/Theirs/current actions still retain their separate confirmation/progress
behavior; the outer Silent option applies only to accepting the checklist.

With both flags, the original literal request runs `git add -f` one selected path
at a time, without a checklist or progress window. This accepts ignored,
unversioned and directory inputs as upstream does; it does not first reduce the
request to conflicted files. A failure or cancellation stops the remaining paths
and retains earlier staged changes. All selected paths are validated for the same
working tree before the first mutation; native permission prompts still apply.
NUL path packets preserve literal names and exact UTF-8 index spellings.

The pinned `ResolveCommand::Execute` and
`ResolveProgressCommand::Run(ResolveWith::Current)` have a specific fourth case:
`noquestion` without `silent` bypasses status population, leaving argv paths
without the `UNMERGED` action bit. Native entry preserves the resulting **Skip**
progress rather than changing it into force staging. It leaves the index unchanged
and retains the normal Close/Commit post-action policy. Use both flags for the
source's direct staging behavior. This is an observed source contract, not a
claim that every upstream version behaves this way.

Successful resolutions remove the source three sibling merge files:
`<path>.LOCAL<extension>`, `.REMOTE<extension>` and `.BASE<extension>`. The native
implementation unlinks only regular files or symlinks, never their targets or
nonempty directories. Other backups remain. Folder/root selection does not delete
neighbor artifacts outside that selected folder; macOS-owned external-tool inputs
keep their existing session cleanup policy.

Resolve and Edit Conflict now share captured command permission/discovery/adoption
ownership. Every input must remain inside the discovered working tree; mixed-root
inputs are refused rather than dropped by relative-path conversion. The original
window and settings survive authorization/metadata reads and workspace adoption.
Resolve window keys and close callbacks retain exact identities; repeated review
entry preserves checks instead of replacing the current model. Silent pending
commands coalesce only for the same exact root/path batch. Closing their initiating
window or retiring the app cancels actual work, retains Quit lifetime until drain,
refreshes possible partial effects and refuses late success/error delivery.

[Batch evidence](qa/resolve-commands-2026-10-18.json) records actual validation and
repairs. Windows HWND refresh messages, process exit status, arbitrary invalid
UTF-8 names, physical source geometry/keyboard/VoiceOver/theme comparison and
current real sandbox/Finder/App Store acceptance remain open. This continuation
does not certify every Resolve dialog or the complete port.


## Notification-list progress — October 19, 2026

Resolve now drains ordered file notifications into the source Action/Path progress list before adding its timed Finished row. File menus and action logs retain their producing attempt. Commit retains the captured repository grant, preferences and appearance and waits for actual result-window/sheet/worker closure. Cancellation question replies also wait for sheet detachment.

See the [connected progress family](SYNC-ADD-RESOLVE-PROGRESS-PARITY.md) for source distinctions, scoped validation and remaining physical, signed and whole-dialog requirements. This continuation does not certify the whole family or port.


## Source row activation continuation — October 30, 2026

The shared [file-list activation family](STATUS-LIST-ACTIVATION-PARITY.md)
separates a double-clicked row from highlighted multi-selection, preserves its
comparison/conflict and Shift-tool intent, and rejects stale sort/reload/closed
receipts. Checkbox events retain their native action; group rows cannot launch
a different selected file. Explicit multi-file menu commands retain their
existing behavior. Physical keyboard/VoiceOver and full-dialog acceptance remain
separate from the connected native checkpoint.
