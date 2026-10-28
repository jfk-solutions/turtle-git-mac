# Commit author controls and metadata lifetime

This is a partial connected native workflow review against pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseProc/CommitDlg.cpp`, `IDD_COMMITDLG` in
`src/Resources/TortoiseProcENG.rc`, and the existing Commit author/date parity
review. The source keeps separate date/time controls, uses a read-only author
field when its override is off, and disables controls during owned operations.
Those source date bounds, time merging, metadata defaults and Git Commit options
remain unchanged by this continuation.

## Native author/date ownership

A native control's current `isEnabled`/`isEditable` state can lag a model update
until SwiftUI renders it. Queued author/date callbacks now also check the live
Commit owner, override choice, metadata loading, operation and Quit gates before
writing a draft. The field stays selectable while read-only. A retired author
coordinator rejects later delegate notifications. Date coordinators detach their
native target/action during dismantling and reject saved old target callbacks,
even when a fresh replacement date control is writable. A closed owner cannot
be changed through native objects retained by an event or accessibility client.

The controller marks itself closing before dismissing any sheet, so synchronous
end-sheet callbacks cannot start another owner action during retirement.
Existing hidden-unversioned Yes/No, suppression, deferred presentation and forced
Close decisions remain part of the same one-shot native prompt lifetime.

Author identity, author date and amend-message reads now share an explicit
`CommitWindowModel.activeMetadataOperations` counter. Each accepted read owns its
entry until its actual async return. Replacing or cancelling a request and closing
its window invalidate tokens/generations and prevent publication; they do not
pretend a noncooperative reader has already finished. Application Quit consumes
this counter alongside the existing Commit reload/file/preference counters.
This does not make accepted Git operations cancellable beyond their existing
runner behavior.

## Hosted failure and scope of the repair

[The official hosted excerpt](qa/ci-commit-log-92654909-2026-10-18.txt) proves that
run `39130261984`, head `92654909`, failed in the first Commit/system-Git receiver
with `SIGSEGV: 11`. It did not reach the Log or bundled-Git case. The job supplied
no crash stack or Commit fixture phase, so the precise crashing instruction and
root cause remain unproven.

The fixture did contain an independent native ownership defect: its manually
retained blocker window was closed with AppKit's release-on-close behavior still
enabled. It now explicitly retains that window across Close, as production
controllers already do, and waits for the actual sheet to detach before closing
the deferred owner. These are scoped correctness repairs, not evidence that they
caused the hosted crash. Flushed phase markers identify the last owned workflow
in a subsequent failure without discarding the original status or assertions.

The expanded existing Commit visibility fixture retains every original check and
adds live Quit/busy fences, old date-target retirement after replacement, closed
native identity/date callbacks, and held noncooperative author/date/amend readers.
It verifies cancellation, actual worker lifetime, application Quit refusal and
rejection of late data. Repository HEAD/index/content assertions remain in place.
The parent owns the grouped build/native checkpoint; fixture existence or a local
focused pass does not establish a complete hosted macOS pass, physical gesture
acceptance, signed deployment, all Commit layouts or whole-application parity.

Actual build/check outcomes and remaining acceptance limits are recorded in the
[grouped batch evidence](qa/metadata-port-2026-10-18.json).

## Option callback acknowledgement — October 28, 2026

The [option-form continuation](COMMIT-OPTION-TRANSITION-PARITY.md#stable-option-transitions--october-28-2026)
keeps an accepted Amend/author/date transition acknowledged across duplicate or
coalesced native view observers. A later observer of an unchanged option cannot
retire the accepted form, restart its reader or replace its prepared draft.
Actual later value changes and explicit metadata refreshes retain their separate
transition, generation, cancellation and worker lifetime. Existing live native
control guards, closed-target retirement and actual pending-work accounting
remain in force.

The [hosted failure excerpt](qa/ci-commit-date-form-eabf99f9-2026-10-28.txt)
retains the failing date-form assertion and its official run/head/job identity.
The [new checkpoint](qa/commit-form-lifecycle-2026-10-28.json) records the scoped
repair checks separately from the older SIGSEGV and metadata-lifetime evidence
above. No fresh installed, physical, signed or complete hosted pass follows from
the source repair itself.
