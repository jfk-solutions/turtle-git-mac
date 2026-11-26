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
