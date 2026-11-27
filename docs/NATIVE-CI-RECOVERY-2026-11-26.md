# Native workflow CI recovery — November 26, 2026

Baseline: main `483fdcc616509b17ff7c2836aababe90d4d78d23`,
[macOS run 45706913427](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/45706913427).
Core and SVN passed; Pages passed independently. The
[grouped repair checkpoint](qa/native-ci-recovery-2026-11-26.json) now passes 46
affected native process cases. A fresh full hosted run remains required.

## Application changes

Compare and Merge distinguish position-preserving Reload from fresh Open/input
reinterpretation. First-read failure leaves Reload available without a text pane;
keyboard, menu and controller entry points retain their owner/lifecycle gates.
Restored horizontal positions use native character zero, including each ruler's
leading inset. See [Reload behavior and limits](MERGE-RELOAD-POSITION-PARITY.md).

The Patch file list now expires captured menu actions on every visibility change.
The review's data generation stays intact. This covers SwiftUI retaining a native
coordinator or coalescing hide/show into one update, which could previously revive
an old Patch command. Native view/window/delegate checks also protect menu, preview
and selection delivery. Fresh actions and the accepted highlighted paths remain
available after showing the list.

Import Patch's Quit/Save continuation previously entered with `confirmingQuit`
set and then rejected that state in the explicit-save options path. The observed
result was a cancelled Quit and unchanged file despite choosing Save. The repair
keeps ordinary UI commands blocked while admitting only the captured Quit-save
continuation; its cancellation and native empty-result question belong to the
same workflow checkpoint.

## Verification corrections

The repair batch preserves the original workflow and byte-integrity assertions:

- Commit submodule policy persists in staging mode without staging or unstaging.
- Format Patch streaming keeps progress on stderr and captured attachment paths
  on stdout. Patch panel fixture compilation uses the existing per-file policy.
- Import previews admit actual owned native panes. Single-line navigation uses a
  real hidden controller and explicit deferred-load admission. Export failure uses
  an invalid regular-file parent; creating a missing directory is supported.
  Export Undo checks the actual encoding history entry before the preceding text
  entry. New-file Auto Add checks source-default CRLF serialization and exact
  encoded bytes in both disk and index, separately from LF native display rows.
- Partial Patch retry first proves the accepted review refuses externally changed
  input, then obtains a new review through Refresh before applying that file.
- English group readiness uses separate semantic builtin/changelist identities,
  even when their visible captions are identical.
- Blame command checks wait for actual native line navigation and consumption of
  its one-use receipt, preserving historical revision and independent viewers.
  The CLI Add deletion case explicitly selects that backend: libgit2's pinned
  add-by-path behavior rejects a missing tracked file, while CLI Add stages it.
- Settings handoffs use scoped private bookmark providers in the unsigned test
  receiver, with required-access and exact captured-lease checks retained.
- Word navigation and image conflict clicks wait for their current native owners,
  projection/readiness and sheet detachment.
- Compare's expected read/save errors are acknowledged through their owned native
  OK buttons before a subsequent F5 or menu command is dispatched.
- Import's ending/marked-save checks use actual invisible native controllers and
  their owned destination editors. Forced-close checks wait for both process/group
  reaping and terminal model state before asserting late-reply suppression.
- RefLog fallback waits for the current native picker context. Commit scope tests
  invoke the real Whole Project acquisition action before checking the roster.
- Standalone Merge checks bind their output through the normal Merge-tool
  invocation. Save/Reload checks exact encoded disk bytes separately from the
  regenerated source result and its saved-baseline dirty state.

The Rebase Add timeout and Log pane-geometry failure pass locally with diagnostic
and ownership repairs, but their observed hosted causes are not established. The accepted
missing-origin comparison retains its original single-row refusal case, with
native position/selection readiness and ownership diagnostics. Those failures are
not declared fixed from a source edit or an earlier local pass.

## Checkpoint policy

Validation is grouped after implementation. It reuses the accepted app/Core/runtime
work and receiver caches, runs failed or relevant unreached families, and retains
unaffected passes. The checkpoint records all 36 build/native command attempts,
including failures and focused repairs; all recorded owned helpers are reaped.
Core source is unchanged; the complete hosted Core pass is
retained. Local native checks do not prove the older-Git matrix, signed sandbox,
physical Finder, minimum macOS, complete visual parity or a full green hosted run.
Build 59 remains the separately installed owner-testing package; it does not contain
this later repair batch. No public binary or App Store submission is included.

## Hosted follow-up on d2a3691e

[The pushed run](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/45775158545)
passed Pages, SVN, app/Finder builds and the earlier Log/RefLog groups. The full
run is still active. Its Replay lane exposed two later failures:

- Bisect's rejected active Start retained its session, but the fixture demanded
  Reset availability while the real error sheet could still own admission.
  Immutable session checks now precede error acknowledgement; Reset must be
  available after the actual sheet detaches. Both Git engines pass locally.
- Rebase Add/system timed out during staging in the reopened no-commit Split
  child. The earlier no-commit commit-recovery phase passed. Its saved process
  stack was not included by the artifact upload, so the product cause remains
  unproven. The middle checkpoint now preserves that existing timeout sample
  alongside the redacted failure reports. No Rebase guard or assertion changed.

The [follow-up record](qa/hosted-native-ci-followup-2026-11-26.json) retains the
verified artifact identity, 54 workflow-contract checks, two affected Bisect
process passes and exact cleanup. No app/Core/runtime rebuild was needed. This
checkpoint does not clear the Rebase timeout or claim a full hosted pass.

## Cancellation and test-context isolation follow-up

The hosted Core suite completed 3,536 tests with three skips and one failure.
Its cancellation test observed an empty PID-marker file before the helper's
`printf` wrote its two fields. Helpers now publish a complete marker by atomic
rename. The same rev-parse/push/stash branches require two distinct positive live
PIDs, exact owned process-group membership, cancellation/reaping and unchanged
stash/index/remote references. Early failures still cancel and await their work.

The Rebase fixture also retained every earlier context's closed controllers in
its diagnostic array. Successfully cleaned contexts now release only their own
controllers after worker, paired-sheet, window and repository cleanup is verified.
Failed cleanup retains its owners and records the failure. This is a concrete
test-lifetime repair; it does not establish the hosted Split timeout's cause.

The [grouped check](qa/hosted-cancellation-recovery-2026-11-26.json) passes the
five-test Core family and Rebase Add/Split with both Git engines. No full Core
suite was repeated. Later failures from the same hosted run are addressed below.


## Accepted action and native-control lifecycle batch

The completed Commit lane exposed a product race: deferred focus bookkeeping
rotated the same epoch used by an already admitted Return comparison. Commit and
Revert now distinguish focus-sensitive menu receipts from primary-action
receipts. Semantic changes still retire both; exact selected rows, staging,
settings, source ownership, cancellation and window guards are preserved.

One incremental app build passed. All nine accepted-operands cohorts then passed
with both Git engines, including held Git reads, an actual focus update after
Return, stale-menu refusal, semantic selection cancellation and the missing-copy
origin error. The first native attempt exposed a fixture error-sheet omission;
the follow-up acknowledges the actual owned cancellation sheet before continuing.

Three additional fixture corrections retain their behavioral assertions:

- Bisect word navigation waits for its accepted form and actual enabled native
  fields before obtaining the field editors.
- Conflict-table Reset waits for the exact native column projection after the
  model accepts defaults, then checks the original native order.
- Statistics dispatches one real AX increment and requires model/AX value two,
  no pending draft, and exactly two included/two skipped authors. The native
  selector's reported Boolean is diagnostic: hosted AppKit returned false after
  already applying the action. No second action or fallback retries it.

These three workflow families pass with both Git engines. Log likewise waits
for its captured reference picker's accepted callback after native sheet and
worker release. Its held-read cancellation scenario explicitly selects CLI in
a dedicated private preference suite: default libgit2 reference reads bypassed
the wrapper, so the expected marker never appeared. Both-engine Log checks now
pass with original range, recents, cancellation and Quit assertions retained. The [batch record](qa/hosted-ci-repair-batch-2026-11-26.json) retains
source hashes, initial failures and affected checks. A fresh hosted run is still
required, including checks that the failed grouped editor step did not reach.


## Hosted Log geometry and Reference Browser follow-up

The fresh hosted history lane reached two further failures: a seven-point Log
file-header movement when a native sheet attached at minimum size, and a
standalone Reference Browser selection check acting before its native rows matched
the model. Log now gives its three existing panes a native split-view controller
that keeps same-size accepted heights, supports native divider movement and
scales/clamps on real size changes. Saved frames restore atomically. The Reference
fixture waits for the actual enabled native row projection, then exact native and
model selection/last-selected identity after each operation. Original geometry,
menu-target, range, clipboard and persistence assertions remain intact.

The [history recovery record](qa/hosted-history-recovery-2026-11-26.json) passes
one incremental app build and six affected native process cases across both Git
engines. The first optional screenshot attempt failed at ScreenCaptureKit (-3811);
that failed attempt and its cleanup remain recorded. The existing app build was
reused for the functional follow-up, with no Core/runtime rebuild. Physical
screenshots and the complete hosted result remain unverified at this checkpoint.


## Sync/SVN command completion follow-up

The primary-command lane progressed through the repaired Bisect cases with both
Git engines, then its Sync/SVN case waited for a visible finished Rebase window.
Source Rebase deliberately forces no-errors automatic close: successful completion
closes that progress owner synchronously after clearing busy state. The fixture
now captures the exact newly created owner and requires its completed result,
closed/detached window, real HEAD fast-forward, information callback and exactly
one accepted source fetch. Other positive/refused commands wait for pending
command authority as well as workspace busy state; question, draft, permission and
repository-effect assertions remain intact.

The [Sync/SVN recovery record](qa/hosted-sync-svn-recovery-2026-11-26.json) passes
the connected family with both Git engines using the already accepted app build.
It preserves complete owner/question/sheet/worker cleanup. No app/Core/runtime
rebuild or full Core repeat was needed. The complete hosted primary family and
remaining lanes still require confirmation.


## Retained Bisect and native Log column follow-up

Completed-step browser logs, later confirmed by digest-verified final artifacts,
identified retained Bisect's compound stale-mark assertion (generated line273,
baseline source line2592) and Log's private column-preference assertion. The
Bisect fixture now establishes an accepted reload and enabled unmarked cached Good
menu before changing the external reference, retaining exact no-new-handoff/error
checks. No product defect was established from the old compound assertion. Three
related Reset/Bisect two-PID writers also publish complete receipts atomically;
these source-proven races were not identified as that failure's cause.

Log's column fixture now invokes the actual one-use header item target/action,
instead of passing its new typed command to the old String-based toggle method.
Real owned Reset answers, native projection, private/global preferences and saved
width inputs remain asserted. The [native batch record](qa/hosted-reference-bisect-recovery-2026-11-26.json)
passes eight affected connected operation cases and two Log column cases across
both Git engines. The existing app build was reused; unaffected hosted cases were
retained.

## Independent group failure collection

The editor runner previously stopped at the first failed compilation/runtime
group, hiding later independent groups and the remaining Git engine. It now keeps
execution order and exact failures, continues only after verified private helper
cleanup, and returns nonzero if any group fails. Each group has a retained private
TMPDIR. Cleanup requires exact approved executable and private-resource evidence,
handles NUL-delimited Unicode/newline/deleted paths, revalidates process lifetime
before individual signals, and refuses continuation for unknown or surviving
owners. Fallback cleanup of a leaked helper also remains a failure. Delegated
native assertions and the existing delegated driver are unchanged. Cases after a failure
inside that delegated invocation may still be unreached; reported totals describe
groups rather than successful cases.

The [orchestration record](qa/native-reference-group-continuation-2026-11-26.json)
retains 17 contract passes, one added real detached-helper/deleted-cwd cleanup
pass, and one actual native Log column group through the updated runner. No
additional app/Core/runtime build or broad native suite was run. These records
support the affected local changes; a fresh hosted run is still required.


## Distribution Preserve-mode list follow-up

The final Distribution artifact identifies source line 722: the fixture expected
Preserve mode to refuse the S action. Pinned `RebaseDlg::SetControlEnable`
(lines 1843–1866) keeps choosing-mode action menu bits, Up/Down and dragging
enabled; Preserve disables Add. Its key handler (lines 811–858) follows those
menu bits. The native implementation already matches this behavior.

The fixture now loads an actual Preserve Rebase plan instead of combining
Cherry Pick with a directly changed Preserve flag. It exercises native-table
selection, S/E/P/Space/Q actions, stable-identity end movement, Add refusal and
drag admission, preserving modifier/window/busy/text-field guards and exact
HEAD/index bytes. The separate retained-Bisect correction remains intact.
The first default local attempt stopped earlier at Log path colors. Explicit
Aqua drawing appearance fixes the unhosted dynamic color conversion while
retaining exact default/configured RGB assertions. A first focused Preserve
attempt then exposed an up-to-date fixture plan; the corrected input uses the
supported Force Rebase option and public branch choice. Both failed attempts
remain recorded, with owned compiler/receiver cleanup.

Validation uses the existing accepted app; no product/Core/runtime rebuild is
required. The full hosted four-Git-version check remains the release gate.

Final metadata for the previous hosted run confirms the unsigned universal
App Store candidate audit, built-framework Revision Graph, packaged SSH lookup,
encrypted SSH-key cleanup and older-Git runtime preparation all passed. The
remaining Distribution failure is the Preserve-mode fixture described above;
this does not certify App Store submission or signed deployment.

The [Distribution recovery record](qa/hosted-distribution-recovery-2026-11-27.json)
retains both failed attempts and four focused process passes across system and
bundled Git. Compilers and receivers were reaped and independently absent; all
other prior passes are retained. The full hosted run remains pending.


## Native Log comparison selection follow-up — November 27

The fresh hosted run passed the earlier Log geometry step112, then failed
step283 in bundled-Git rename selection. Its bounded, digest-verified artifact
shows a timeout before the fixture requested table focus: equal row counts did
not establish the native table's current rename projection. The first-responder
name and AttributeGraph warnings alone did not prove a product focus defect.

The shared fixture now waits for the actual data-source/model and forwarded
delegate identities, exact native path bytes/group slots and model/native
selection reconciliation before selecting once. Existing Return, selected IDs,
captured operand, backend, bytes, cancellation and owner assertions remain.
The first new guard incorrectly assumed an unwrapped delegate; that failed
attempt remains recorded and is corrected without bypassing the selection proxy.

The [Log comparison recovery record](qa/hosted-log-operands-recovery-2026-11-27.json)
passes eight comparison and two primary-activation native process cases across
system and bundled Git. Existing app objects were reused; no product/Core/runtime
build, installed60 update or broader local suite was required. Owned compilers
and receivers were reaped and independently absent. The current hosted run is
still collecting results; corrected-source hosted acceptance remains pending.


## Combined reference and replay recovery — November 27, 2026

Run 45995227210 passed the complete Core, Settings/Finder and Images/Documents
lanes. The Commit lane failed while downloading its artifact, before executing
native tests. History failed in step 283 (covered above); Editors failed only its
grouped reference step 305. Replay failures 201, 274, 275 and 388 were investigated
using the actual failure artifacts or expanded hosted log. The current run still
contains the old source, so local recovery does not make that run green.

The reference batch updates source-backed native fixtures together: canonical
captured repository identities, current native report coordinators, one-use menu
ownership, actual sheet dismissal, settled asynchronous publication, and private
CLI selection only where a test intentionally intercepts a CLI process. It keeps
normal backend coverage, byte-exact operands/index/HEAD checks and cancellation
assertions. Failed cases now continue only after verified owned-process cleanup;
unknown ownership stops the batch. Three offline contract groups cover that
continuation, complete case inventory and compiler grouping.

Three product corrections accompany those fixture repairs. ChooseVersion Log
handoffs set the selected hash without appending it to custom revision history,
as pinned ChooseVersion distinguishes SetWindowText from SelectRef/AddString.
Log changed-file Home/End select and focus endpoint files, with guarded Shift
ranges across native repaint. Working-file Delete can complete an unknown
retained-copy classification from fresh status, while preserving every other
exact status fact and rejecting changes to known classifications. The latter
was reproduced: the commit read omitted ignored inventory but fresh Delete
inspection classified the same retained local copy as ignored.

Replay Add acknowledges the actual owned conflict error sheet before Continue,
without changing Rebase state or conflict bytes. Historical graph-export checks
validate the real enhanced-metafile record stream for the existing WMF/EMF
aliases; no image renderer behavior changed. Held Cat checks intercept their
intended CLI backend. Switch/Reset/Bisect receiver compilation is grouped by
its three related workflow families, retaining all 15 cases and their original
per-compiler timeout. Its original failure was compiler timeout, not a runtime
workflow failure. Sync/Replay retains its existing timeout and gains bounded
owned-state diagnostics; its original hosted timeout is not explained by a local
pass alone.

Completed local checkpoints retain all earlier passes. Add preparation, primary
historical commands, Sync/Replay, version-picker lifecycle and Reset picker pass
with both Git executables. All 15 Switch/Reset/Bisect cases pass with both Git
executables. Further validation is restricted to the remaining actual failures
and the new Core/Log changes. See the [combined recovery record](qa/hosted-reference-family-recovery-2026-11-27.json)
for exact scope, failed attempts and limits. Installed build 60 is unchanged;
corrected-source full hosted acceptance and release delivery remain pending.


The final affected checkpoints pass native changed-file endpoint navigation,
three-pane ending/menu/Undo/Redo behavior, replay file menus/mutations, Blame
file-open/atomic auxiliary MRU, and the entire Add/restoration/Revert/index-flag
workflow with both Git executables. Fourteen focused WorkingFileDeleteTests
also pass. Add's final stale Revert rejection was caused by its fixture omitting
the captured invocation paths and policy that production already forwards;
correcting that handoff preserves the exact stale-selection guard. The fixture
also waits for both actual worker counters before checking post-read cleanup.
All failed attempts remain recorded. Owned compilers/receivers were reaped and
independently absent at each checkpoint. The full corrected-source hosted run
remains required; no installed-app update or full local Core rerun was made.


## Last Distribution receiver and workflow contracts — November 27

The old run completed with one further Distribution failure, step 453, at the
initial Cherry Pick oldest-Squash assertion. Pinned `RebaseDlg.cpp`:367 refuses that
action; the native setter correctly leaves its valid plan intact. The fixture
now checks exact refusal, legal non-oldest Squash, public reordering to an
invalid first-Squash plan, and restoration before the original mainline flow.

Subsequent checks exposed obsolete preflight-parent expectations. The current
[reached-parent contract](REBASE-MAINLINE-PARITY.md) preserves an active durable
checkpoint on Cancel and resumes it through Continue. The updated fixture checks
that exact occurrence, parent ordering, HEAD/index and once-per-phase callbacks.
Empty Commit also follows the documented
[two-phase message contract](REBASE-CONFLICT-MESSAGE-PARITY.md): an original
empty commit can succeed while its attribution amendment fails without
`--allow-empty`. Explicit Retry/Continue/Ignore preserves the original empty
commit; a separate no-attribution case verifies ordinary successful Empty
Commit. Both retain exact message, author, date, parent, tree and index checks.
Squash approval now checks the immutable raw commit body rather than Git's
pretty-output separator. The retained failed repository independently proved
that the approved 48-byte body was already correct while formatted output had
one extra LF.

The related Recovery helper uses the actual typed stage-1 Base comparison,
including captured alternate-tool routing, and waits for actual menu workers.
Reference starts consume their real confirmation receipt. Menu Push separately
checks ordinary label eligibility and extended hash routing through actual
private branch/tag catalogs. Source data, stale/one-use admission, cancellation,
notes, export ownership and completion checks remain. A focused complete replay
family retains all later Split/recovery/Squash/reference/menu helpers; the full
CI default still runs every original prefix and assertion. Previously completed
unrelated prefixes are retained during local recovery.

The first corrected-source run 46027551147 (source `24525833`) stopped at its strict workflow contract:
the reviewed middle diagnostic upload gained three Add receipts, but its exact
checker still expected two paths. The checker now requires all five and permits
only the exact three-command Core contract augmentation, retaining the immutable
original inventory, owner, order and conditions. All original 54 contract tests
plus two related negative contracts pass. The changed Log integration passes
with system and bundled Git. See the [late recovery record](qa/hosted-distribution-selection-recovery-2026-11-27.json)
for failed attempts, final native scope and remaining hosted gate. No additional
app/Core/runtime build or installed build 60 update is part of this follow-up.


The final local checkpoint passes the complete bundled-Git replay-selection
family. System-Git passes for the unchanged connected pre-menu families are
retained; the final Rebase menu and Log integration families separately pass
with both Git engines. This is the actual union of local coverage, not a claim
of a new complete System-Git run or full hosted acceptance. The last menu
fixtures use a separately authored unreferenced commit and real CAS-guarded
branch/tag catalogs, rather than assuming an existing row lacks labels. They
also set session auto-start intent after the final load/setup and verify the
exact stored/reopened metadata and automatic-close count. All owned compiler
and receiver processes were reaped and independently absent. No further local
suite or application build is needed before the corrected-source hosted run.

## Rebase Add cumulative receiver deadline — November 27

Run [46041091755](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/46041091755),
source `382535b7`, passes the complete History/References lane and the previously
failed primary-command and Sync file-activation checkpoints. The complete run
is still active. Rebase step 201 fails in the system-Git Add receiver.

The middle diagnostic artifact `15226811260` preserves its complete stdout,
stderr, timeout receipt and process sample. The receiver reaches the last Split
workflow at 238.027 seconds. Its final staging wait completes at 297.503 seconds;
the following finish wait then has only 2.497 seconds before the existing
300-second process deadline. Earlier native waits continue completing, and the
sample does not establish a hung product operation. This is evidence of an
insufficient cumulative process budget for the combined fixture, not evidence
that the application needs a larger operation timeout.

The recovery separates independent Add workflow cohorts into owned receiver
processes while retaining one combined receiver compilation, all original Git
and native assertions, the 300-second process limit and each original native
wait limit. The [grouped recovery checkpoint](qa/hosted-rebase-add-cohort-recovery-2026-11-27.json)
passes all four cohorts with system and bundled Git: eight owned receivers in
234.344 seconds, plus five offline execution/isolation contracts. All owned
compiler/receiver processes are reaped and independently absent. The cached
build's 501 App/Core Swift sources match the current source; no product rebuild
or local full Core rerun was needed. Complete corrected-source hosted acceptance
remains required. No application/Core change, new metafile work or installed-app
update is included in this correction.

## Editor, Finder recovery and graph decoder follow-up — November 27

The same diagnostic run completes the History/References, Core,
Commit/Repository and Settings/Finder lanes successfully, but reports additional
failures in the editor and image lanes. The pending intermediate Rebase-only
run was cancelled so the next complete run can include these related repairs.
The [follow-up record](qa/hosted-editor-image-statistics-recovery-2026-11-27.json)
distinguishes actual hosted failures, local checkpoints and unresolved causes.

Patch Panel exhausted its existing 300-second compiler deadline before runtime.
Compilation now uses cohesive cached groups, retaining every complete original
fixture body, default case, Git ordering, assertion and deadline. Six offline
contracts and all eight affected native case/engine executions pass locally.

The grouped reference report contains three failed cases: unsigned Finder grant
transfer, Finder watches and Blame pane menus. The grant worker now uses actual
non-app-scoped Foundation bookmarks consistent with its existing unsigned test
scope. Blame waits for the exact current attached Log caption before its native
accessibility action, rather than admitting another pane and force-unwrapping a
missing Log caption. Both repaired cases pass locally with owned cleanup.

The remaining watch failure reproduced after linked-worktree administration
permission was revoked. Recovery installed a replacement session, returned
before its scheduled first read, and reported success. The subsequent failed
read then restarted immediate recovery, repeatedly replacing the session and
hiding the stable permission error. Restoration now awaits that exact
replacement's first collection under the same owner and cancellation token, so
the real result controls the existing bounded retry backoff. The original
permission, cached-roster, lease and 20-second checks remain in place.

The affected image cases pass locally after reconstructing and verifying the
exact committed runtime kit, including its complete source, renderer, resources,
licenses and native linkage. The old validation cache's different recipe is
retained separately. These passes establish the focused local behavior; they
do not prove why the hosted decoder previously omitted an image. No renderer
feature is added. The unchanged combined ROI wait budget now reports whether
decoding or native pane mounting is incomplete.

Three Statistics consumers previously reported an otherwise bare decoder
timeout. Diagnostics now identify the exact graph, format, helper and elapsed
operation, and preserve the generated failing input plus metadata. The final
hosted failure artifact includes only those exact generated files alongside
the existing redacted reports, never private repository/home trees. Decoder
and receiver deadlines, independent graph/vector/pixel assertions, and the six
already-passing Statistics export cases are retained. Complete corrected-source
hosted acceptance remains required; installed build 60 is unchanged.

The final local checkpoint passes the failed Finder watch family after its
single product repair, retaining the earlier grant and Blame passes. All nine
Statistics receiver cases pass: the original default dialog family with system
Git, authors with both engines, and all graph Statistics/Revision/ownership
cases with both engines. The 82 decoded graph payloads complete within the
unchanged 15-second operation deadline (maximum locally 0.558 seconds). This
does not reproduce or establish a fix for the hosted decoder timeouts. The
incremental Debug build, 57 exact workflow contracts and dialog-coverage
reconciliation pass. All observed owned compiler/receiver processes are reaped
and independently absent. No repeated full Core suite or unaffected native
families are part of this checkpoint.
