# Submodule comparison and conflict dialog actions

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
Implementation baseline: `62330c51`. This native workflow family passed its
scoped grouped checkpoint after the recorded compiler, caption and fixture repairs.

## Source contract

Resource references are `IDD_DIFFSUBMODULE` and `IDD_RESOLVESUBMODULECONFLICT` in
`src/Resources/TortoiseProcENG.rc`; both remain partial dialog reviews.

`SubmoduleDiffDlg.cpp::OnInitDialog` and `OnBnClickedShowDiff` distinguish the
primary button action from the dirty-submodule dropdown. Identical revisions
open child Working Tree status. A dirty comparison of a known change offers
**Show diff** between the displayed child commits and **Compare** against the
working checkout. The chosen dropdown entry becomes the primary button action.
Dirty Unknown uses the working checkout. The source button is disabled if either
side is unavailable. Update appears for an unavailable side or a working-tree
comparison. Both Log buttons pass the displayed child hash as both `/endrev` and
`/rev`; Shift is sampled for the actual comparison action.

Source F5 ends the current dialog and reconstructs it with new metadata. The
native port refreshes in place, retiring actions captured from the old display
and resetting the primary action for the new snapshot. The selected action is a
per-display choice, not a new global preference. Existing dialog geometry and
source colors retain their separate persistence and presentation contracts.

`SubmoduleResolveConflictDlg.cpp` and `IDD_RESOLVESUBMODULECONFLICT` place Base
Show log beside Revision. Mine and Theirs place Show log beside Type and Use this
beside Revision. An unavailable subject has white text on red; forward, rewind
and divergent commit-time types use the source green/pink/blue/orange/gray colors.
Source child Log carries both selected and ending revision. Rebase side labels
retain their actual stage identities. The existing Resolve/Reset continuation
and deletion recovery remain the Git operation contract.

## Connected native scope

A displayed comparison action must bind its exact metadata snapshot, owner,
generation and originating preferences. F5, Update, Quit confirmation and closure
retire retained actions. Captured dropdown callbacks must not silently act on
newer metadata. Current-click Shift belongs to the accepted action, including
asynchronous child-repository preparation.

Visual closure is separate from worker completion. The closed comparison or
conflict controller must retain its permission lease, update/options/progress or
Reset children, and pending questions until actual workers and native sheet
detachment finish. Its cache-removal callback follows that drainage. A comparison
that discovers a conflicted gitlink hands off to the conflict chooser after its
read and original owner retire, rather than opening a new chooser during the old
read. Late answers and child callbacks cannot revive a retired owner.

Conflict windows must distinguish independent originating preference domains in
their cache identity. Child Log and Reset receive that captured domain. A global
Quit confirmation blocks idle conflict actions as well as comparison actions;
cancellation resumes live owners without granting authority to old replies.

## Verification boundary and remaining work

Eight distinct native case/engine pairs passed across the grouped checkpoint and
affected routing repair, with system and packaged Git. The checks cover real split
controls, source action routing, stale display receipts, original preferences,
held readers and Update processes, cancellation questions, cache replacement,
cancelled Reset and successful Reset followed by exact gitlink resolution.
All eleven receivers, including the failed fixture attempt, were reaped and
independently confirmed absent. Four complete offscreen light/dark windows were
reviewed; the final conflict pair includes the escaped macOS filename header.

The Debug commands after the compiler repair exited zero and current app objects
passed native source/object freshness and linking checks. Their contradictory
SwiftCompile failed-with-exit0 diagnostics remain recorded. This is not a clean
hosted SDK build claim. Core was unchanged and was not rerun.
[Dated evidence](qa/submodule-review-family-2026-10-21.json) records each attempt
and the focused repair scope. This does not prove complete Submodule Diff/Resolve parity, physical
keyboard/VoiceOver/Finder behavior, every missing-object or mixed-type case,
signed repository grants, minimum macOS/Intel execution, full hosted CI or App
Store distribution. These remain explicit acceptance work.

Actual [comparison light](site/assets/submodule-review-comparison-light.png) /
[dark](site/assets/submodule-review-comparison-dark.png) and
[conflict light](site/assets/submodule-review-conflict-light.png) /
[dark](site/assets/submodule-review-conflict-dark.png) captures show the current
native forms. They do not cover every unavailable/type/rebase rendering state.

See [Submodule Diff](SUBMODULE-DIFF-PARITY.md),
[Submodule conflict](SUBMODULE-CONFLICT-PARITY.md),
[Update recovery](SUBMODULE-UPDATE-RECOVERY-PARITY.md) and
[conflict identities](CONFLICT-IDENTITIES.md).
