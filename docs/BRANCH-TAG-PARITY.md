# New Branch/Tag dialog parity

Reference: `CreateBranchTagDlg.cpp`, `IDD_NEW_BRANCH_TAG`, BranchCommand,
TagCommand and `CAppUtils::CreateBranchTag` at the commit in `upstream.json`.

The separate native windows retain Name, Base On, Options and Description/Message
in the upstream order. Base On has HEAD (current branch), Branch, Tag and Commit
radio rows with aligned selectors and browse buttons. Branch and Tag share the
same implementation. App/Finder commands and log revision actions open it; the
latter preselect the exact commit rather than assuming HEAD.

Branch mode supports automatic/explicit/no remote tracking, Force, and Switch to
new branch, plus a multiline description saved to local Git configuration. Remote
selection suggests the remote branch name when the name is empty or still the
previous default. Editing that name disables automatic tracking. The switch
preference is remembered; bare repositories hide switch. Production creation with switch checked opens the shared native Switch result.
Its failure retains the new branch and offers Stash, Retry and Switch with merge.
Headless callers without a Switch presenter retain the earlier inline checkout
compatibility path and Retry checkout. Neither path recreates the branch.

Tag mode uses the text area as its message: empty creates a lightweight tag;
nonempty creates an annotated tag. Sign requires a configured signing key and a
message. The unchecked Sign option overrides Git's automatic tag signing setting.
Force permits updating an existing reference, subject to Git's checked-out branch
protection. Cross-type name collisions ask Continue/Abort before mutation.
Tag Push opens the native Push window scoped to the newly created full tag ref.
See PUSH-PARITY.md for its options and remaining differences.

## Evidence

Four real Git integration tests cover branch descriptions with mixed staged/later
unstaged changes, lightweight and annotated tags, forced tag replacement,
unchecked signing configuration, signing-message validation, remote tracking,
shared branch/tag names, invalid names/revisions and checked-out branch protection.
The historical Swift suite at that checkpoint had 76 passing tests; this is not a current full-suite claim.

Native QA on the disposable documentation repository created a branch with a
multiline description, an annotated tag with a multiline message, and a second
branch with Switch to new branch checked. Git verified each reference and its
metadata and confirmed HEAD switched to the second branch. Index/worktree patches
matched byte-for-byte after all three operations. The fixture was returned to main.
A further native check created an annotated tag with Push checked, opened the
ref-scoped Push dialog, and sent only that tag to a disposable bare remote without
changing index/worktree patches. The actual native captures are `site/assets/create-branch.png` and
`site/assets/create-tag.png`.

## Remaining comparison work

- Full Browse References tree and selection-mode Log, revision history/completion.
- Interactive signing/key prompts and native signing verification.
- Native remote tracking/force/cross-name warning checks, failed-checkout retry,
  bare repositories, light appearance, keyboard, resizing and accessibility QA.
- Physical shared Switch ownership/cancellation and description retry acceptance;
  legacy callers without a Switch presenter still lack complete description recovery.
- Full settings/size persistence and a broader supported Git-version matrix.

This dialog remains partial in the upstream inventory. It is not full parity or
an App Store-ready release.

## Captured creation and Switch handoff

Production branch creation now follows CAppUtils::CreateBranchTag: create the
reference, run PerformSwitch when requested, then save a nonempty branch
Description after that result is acknowledged, even when checkout failed. The
native shared Switch model supplies its source-ordered success/recovery actions,
original icons and close policy. The options remain locked behind its sheet;
this retained ownership differs from upstream's closed options. Root refreshes
reference views after actual creation and repository views after Switch attempts.

Core createReference retains its existing default description behavior for old
callers. Production can defer it, then calls updateBranchDescription with captured
name/message, CR removal and trimming; a whitespace-only description removes
the prior config value. A foreign config lock preserves the created
reference and exposes Retry description; that retry cannot recreate or re-checkout
the branch and uses the original message. Surfacing/retrying a description failure
improves upstream's ignored SetConfigValue error; full partial-failure recovery for
legacy no-presenter callers remains pending.

Tag Push uses the submitted checkbox and full created tag ref, including after a
cross-name Continue warning. Cross-name Continue keeps original options/intent;
Abort clears the pending request. Load/create cannot replace running, warning or
completed states. Explicit HEAD presets select the HEAD radio. Production factory
requests receive separate options controllers so another requested base cannot
replace an existing draft. Close/Quit guards include chooser reads, mutation and
pending name warnings; closing invalidates late callbacks. Store creation and
post-Switch description writes check the retained root lease. Signed acceptance
remains unverified.

[Handoff QA](qa/branch-tag-handoff-2026-10-08.json) records six focused Core tests
and four-Git actual branch/tag creation and real Switch models: description timing,
failed-checkout actions/ref retention, config-lock preservation/description-only
retry, captured Push/cross-name choices, explicit HEAD/load/duplicate guards and
native close/Quit/invalidation. Actual Root factory/new-window/nested-sheet
interaction, UI warning defaults and Push destination remain physical acceptance
work. The hidden controller's view is removed before inducing a warning so the
receiver cannot display an alert; controls are hosted separately without a window.
No actual network Push occurs. Existing screenshots predate this completion flow.

## Full shared revision pickers

Create Branch and Create Tag now own the native all-reference namespace browser
and full typed-revision single-selection Log through `VersionPickerCoordinator`.
The reference tree/list supports local branches, tags, remotes and custom/notes
namespaces. A fresh return catalog classifies the canonical selection into the
Branch/Tag/Commit control; Cancel refreshes the original selection. Native revision
controls receive a once-only focus request, and branch/tag handoffs preserve the
unused commit draft. Log shows the typed ancestry, graph and details without the
Working Tree row and returns a full hash.

HEAD, busy, pending-name-conflict and already-created states prevent new picker
requests. Parent creation, competing requests, close and Quit are gated while a
picker or return catalog is pending. The shared owner rejects stale replies and
releases rejected/closed children. Name, description/message, Force and follow-up
options remain separate from chooser defaults; remote-name suggestions retain
the existing parent behavior. App factories configure canonical Log/Browse/Compare
context actions with the retained repository lease.

[Creation picker QA](qa/creation-pickers-2026-10-09.json) records hidden native
controller checks followed by actual private branch/tag creation at the chosen
Log revision, plus the existing captured handoff regression. Injected presenters
release parent focus and never order windows or show real sheets. Physical input,
sheet restoration, error/close-during-load recovery, visual/theme/accessibility,
complete browser/Log commands and signed acceptance remain pending. Existing
screenshots predate these routes.

## Owned creation cancellation and browser entry

Create Branch can now be entered from a selected remote ref in the native
reference browser. The source passes its stored object hash; this route retains
that immutable Commit base and refreshes the browser after closure. Standalone
and owned routes share repository interaction configuration. See
[reference browser parity](REFERENCE-BROWSER-PARITY.md).

Initial metadata and reference creation have owned cancellation tokens. Forced
closure cancels the chooser and its independent metadata/creation work, rejects
late state/error publication and preserves completed mutations. Core creation
threads cancellation through validation, existence/revision lookup, mutation and
description; ordinary error/default behavior remains compatible. Description
retry also owns a token. Routed checkout/switch completion and all failure variants
still need broader lifetime and physical/signed acceptance.

The commit-revision row now uses the shared [editable session combo](VERSION-COMBO-PARITY.md),
including programmatic custom choices, exact native Git token identity and
disabled/retired/focus guards. Physical popup and complete dialog acceptance remain open.


## Owned creation, cancellation and completion — October 16, 2026

Pinned `CreateBranchTagDlg.cpp` and `IDD_NEW_BRANCH_TAG` retain Name, Base On,
Options, Message/Description and OK/Cancel/Help. The native dialog keeps those
controls and source-dependent Track/Force/Switch/Sign/Push states. Force, Sign
and Track now have the corresponding source tooltips. The source tracking-name
rule compares the suffix of the selected remote, so an explicitly tracked `topic`
can retain Track when based on `origin/team/topic`. Queued base/name notifications
cannot rewrite a picker-owned or already-created draft; suggestions resume after
the owned read or picker returns.

`CAppUtils::CreateBranchTag` performs creation, optional Switch, then description
and optional Tag Push. Native completion now retains the created reference and
captured options independently of the remaining phases. Standalone callers always
save the branch description separately, matching the production Switch handoff.
A description failure offers description-only retry without recreating the branch
or repeating checkout. A failed fallback checkout retains its captured branch and
checkout intent. Repository notification runs once for a created reference; a
Tag Push uses the captured tag name and dispatches after completion/closure.

Cancel remains available during creation and metadata reads. Creation and
Description retry respect ConfirmKillProcess with owned Yes/No questions; No
continues, Yes cancels the current token and closes after actual worker drain.
Normal Close during creation uses the same route. Initial-read Cancel drains both
independent metadata readers. A naturally completed operation waits for its
outstanding cancellation question before closing or dispatching Tag Push; duplicate
or old replies do not cancel another phase or repeat the handoff. Cancellation
retains completed Git effects and does not remove a created reference.

Forced owner retirement cancels Git and closes its owned Switch progress sheet.
The pending Switch acknowledgement settles once so the parent cannot retain a
suspended continuation or write its description later. The child retains its own
existing process/Quit lifetime; the parent now also counts creation, description
and cancellation questions independently of its window. Private preferences flow
into the production Switch progress model. Retired workers refuse UI, error,
closure and Push publication while retaining access until they return.

Core creation now parses and validates the resolved object from stdout separately
from successful diagnostics on stderr. Warning text cannot become part of the
branch/tag's commit identity. This retains Git's resolution policy for manually
entered short references.

See [grouped evidence](qa/branch-tag-completion-2026-10-16.json) for actual build,
Core/native results, any repairs and process cleanup. These checks do not certify
all source focus/balloon behavior, physical signing/transport prompts, complete
visual/VoiceOver parity, signed sandbox handoffs or App Store acceptance.

## Source form and exact creation handoffs — October 17, 2026

Name, Base On, Options and Description/Message retain their source order. HEAD is
left aligned with the other radio rows. Captured name/options/message/base/focus
and Browse bindings reject a replaced load, active picker, busy or created form,
cancellation and closed owner. Name changes and remote-name suggestions compare
exact UTF-8, so an edited canonical Unicode spelling is not replaced as an old
suggestion. Picker intent now includes all creation flags and message text.
Native name focus follows load completion. Explicit content sizing keeps the form
and footer within a resizable native window.

The shared three-state Track checkbox now honors its parent's disabled state,
updates rapid clicks synchronously, and retires on native teardown/owner closure.
Base radios retain that same owned button lifetime. These choices are also used
by Switch, Worktree Create and configuration-source forms; their source meanings
and existing three-state order remain unchanged.

Creation validation, base resolution, branch/tag writes and descriptions preserve
exact names/messages using a command-only `core.precomposeunicode=false` override.
The connected Switch and Push validation/mutation paths use it too, so a newly
created name cannot select a canonically equivalent ref for a follow-up action.
Persistent Git path preferences are retained. Missing-ref checks distinguish an
ordinary absence from other Git failures. Ref checks remain preflight guards,
not an atomic multi-ref transaction. Normalizing filesystems can still constrain
coexisting loose names; full filesystem/transport/signing acceptance remains open.

All 22 previously pending static controls now receive partial mappings (24/24
including existing Help/footer mappings). The build and eight grouped native
case/engine runs pass. Initial Core failures exposed command-wrapper error
arguments and normalization of catalog reads; both were repaired. The 13 affected
Core checks then passed; the other 22 initial checks had already passed. Native
validation first required a fixture entry-point repair, then found asynchronous
Track updates after a later click. Name-dependent tracking now updates
synchronously in the model, and the native fixture waits for rendered readiness.
Four raw light/dark captures were individually reviewed; all owned receivers were
reaped and independently absent. See [batch evidence](qa/branch-tag-source-family-2026-10-17.json).

The grouped checks cover actual private branch/tag creation, description, Switch,
Push handoffs, private bare-remote push, recovery, cancellation, reference/Log
pickers and retired controls with system and bundled Git. Native split-view
layout warnings remain in the hidden picker harness. Signed tag/key prompts,
complete physical/keyboard/VoiceOver, all Git/version/locale/FS boundaries and
signed sandbox/App Store acceptance remain open. No full port certification is
claimed.

## Source acceptance and native creation lifetime — October 19, 2026

Pinned `CreateBranchTagDlg::OnBnClickedOk` validates the signed-message/name,
existing-name and cross-type-name form first. Continue/Abort defaults to Abort.
Only accepted forms save `NewBranchSwitchTo`/`PushTag`; base resolution and the
actual `CAppUtils::CreateBranchTag` Git operation happen afterward. Native creation
now separates those phases instead of writing checkbox defaults before validation.
An invalid name or cross-name Abort leaves them untouched. An accepted form still
remembers its captured choice when later base resolution or mutation fails.

Core exposes immutable validated-form/prepared-plan boundaries. Options callers
retain the original convenience API, which follows the same validation and Git
argument construction. Preparing a form/plan does not create references or write
branch descriptions. Local/tag plans retain their resolved hash; remote tracking
retains the captured remote refname so Git continues to honor its tracking policy.
An external writer can move that remote between preparation and execution; this
is not an atomic ref/config transaction. Exact UTF-8 names/messages and existing
Force/Sign/annotation/tracking semantics remain.

Native cross-name, error and kill questions are controller-owned, one-shot and
matched to the current form/owner. Accepted replies wait for actual sheet detach;
Abort/error acknowledgment restores name editing/focus where applicable. The
macOS error acknowledgment adapts the source edit balloon. Quit generations,
forced closure and duplicate/stale replies cannot accept another form or handoff.
Per-instance queued-work ownership retains actual load/create/description and
chooser/Switch work after invalidation; native releases retain detached question
and picker completion. A retired form's `onClosed` waits for real drain.

A created branch retains its captured Switch/description sequence, including the
description-only retry after a config failure. Real owned Switch acknowledgement
comes from its actual closed/drained controller, rather than an early forced-owner
continuation. Tag Push captures the full created tag, original permissions and
preferences, and an appearance/opacity value before closing. It dispatches only
after intended creation-window/native-child closure. Forced closure drops a
queued Push; repository creation notification remains once-only.

[Grouped evidence](qa/branch-tag-creation-family-2026-10-19.json) records actual
validation after the implementation freeze. Physical balloons/keyboard/VoiceOver,
all visual/source variants, signed GPG/key/transport prompts, signed sandbox/Finder
and App Store acceptance remain open. No generic command-progress window or new
post-action is added to this source direct-Git creation workflow.


## Native source form control continuation

[The connected form family](SOURCE-FORM-CONTROLS-PARITY.md) records reference
keyboard/focus and bounded captions, Push F5 refresh and Synchronization native
split controls, with owned state and remaining acceptance kept explicit.

## Accepted creation after late Cancel — October 29, 2026

The connected [creation outcome family](CREATION-OUTCOME-PARITY.md) separates
actual Git acceptance from subsequent cancellation and identity verification.
Captured parents refresh once, completed refs are retained before owner guards,
and explicit continuation does not repeat creation. Fresh direct/peeled identity
reads keep successful diagnostics separate. See the [grouped evidence](qa/creation-outcome-2026-10-29.json);
this continuation does not establish full physical or signed dialog acceptance.

## Shared creation-picker focus ownership

The hosted creation-picker receiver timed out while waiting for the parent base
reference control to regain focus after an accepted reference. Its old generic
line71 timeout did not distinguish disabled/missing controls, a rejected form
receipt, native responder eligibility or sheet detachment. That timeout alone
does not establish which readiness condition failed on the hosted machine.
The first focused native recheck passed the shared control lifecycle assertions
but reported an enabled, focusable parent control with `referenceFocusRequest=0`.
That localized a separate acceptance defect: the coordinator reused the parent's
new-picker gate when accepting its already-owned child. Branch/Tag and Worktree
new-picker gates correctly require no current picker, so that guard rejected every
valid return before selection or a focus intent could be published.

The coordinator now distinguishes new-picker admission from accepted-child
admission. Creation parents retain the same lifetime, error, busy, operation and
context guards while allowing their current owned picker to return. The captured
request, chooser draft and parent draft still refuse stale/replaced results.
Switch's existing lifecycle-only predicate and Merge/Export's model-owned
admission do not have that no-picker contradiction and retain their behavior.
A cancelled reference child now finishes its owned picker directly, without a
reference reread, chooser defaults, parent selection callback or new focus intent;
base text, custom tracking/override options and unused drafts remain intact.

The shared reference popup and editable revision combo now explicitly accept
programmatic focus while enabled, independent of ordinary Full Keyboard Access
Tab-navigation policy. A control-bound delivery keeps the existing model's
accepted focus request pending through native attachment, enablement and sheet
completion. It retries only on those native lifecycle events and SwiftUI updates;
there is no timer or continuous retry loop. A consumed request does not replay,
and dismantling, window Close or moving the same native control into another
window retires delivery. Existing model target, form-context, busy, sheet, Quit
and retirement guards remain authoritative.

Branch/Tag uses its existing captured form context. Worktree's connected base
controls now use the parent creation-form receipt as well as the chooser context,
so mounted controls cannot bypass parent ownership during or after a picker.
The chooser still owns canonical reference/commit selection, asynchronous reads,
child release and the one accepted return intent. Picker cancellation and rejected
presentation retain the draft and do not invent a new focus request.

The existing creation-picker receiver retains its real Branch/Tag/Worktree,
canonical Unicode/reference, Log, creation and stale/closed-child assertions. It
adds native delayed attachment/enablement, one-shot focus, replacement-window
refusal and old Worktree base-receipt checks. Accepted focus waits now report the
specific kind/reference/target, native eligibility/responder, sheet, request,
busy and error state. Canonical accepted revision and exactly one new focus intent
are required before the native focus wait; Cancel retains the exact draft/options
and focus counter. The actual `firstResponder` assertion is retained.

The [connected lifecycle checkpoint](qa/creation-finder-lifecycle-2026-10-31.json)
records the Debug build and final native pass with system Git, including actual
private Branch/Tag/Worktree creation and exact first-responder checks. It retains
the initial acceptance failure and the later SwiftUI-subview fixture repair; only
affected checks repeated. No complete hosted, signed or physical keyboard
acceptance is claimed. The protected shared reference-batch runner is unchanged.
