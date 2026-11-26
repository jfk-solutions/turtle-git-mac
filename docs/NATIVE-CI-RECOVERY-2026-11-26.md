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
