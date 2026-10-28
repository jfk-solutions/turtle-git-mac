# Commit options, list suspension and amend draft transitions

This connected partial review follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`, `CommitDlg.cpp`:
`OnBnClickedCommitMessageOnly`, `OnBnClickedCommitAmend`, `OnUpdateOKButton`,
`PrepareStagingSupport` and the existing commit/progress actions, plus
`Resources/TortoiseProcENG.rc::IDD_COMMITDLG`.

The existing source checkbox layout, same-list three-state staging, right-hand
partial patch companion, author/date fields and Commit/ReCommit/Commit & Push
split action remain in place. This continuation does not add more checkboxes or
claim those existing screens as newly implemented.

## Message-only disables the file list across native routes

The Windows handler disables the entire status list when Message only is
checked. The native table already looked disabled, but several model and delayed
native callbacks could still change inclusion or stage files behind that view.
A single `fileListAvailable` policy now controls the native checkbox and key/
column/copy probe as well as classic inclusion, grouped checks, staged checks,
index flags, Add/Delete, LFS, changelist and file comparison dispatch.

Each Message only transition also retires the file-menu generation. An already
captured context action cannot execute while suspended, nor revive after the
option is turned off. Direct stale checkbox/Space callbacks likewise refuse
changes. The existing drop refusal remains in use. File rows, highlighted and
checked memberships are retained so turning the option off restores the user's
selection instead of silently rebuilding it.

The message editor and Commit remain available under their original message/
operation guards. Separate View Patch/Partial Staging/Partial Unstaging controls
retain their existing source policy; this is not a global block on index tools.
Unversioned visibility, staging mode and the other options outside the disabled
list preserve their existing behavior and persistence.

## Amend failure and draft ownership

Ordinary Amend swaps the normal and amend drafts and loads HEAD's message when
no amend draft has been retained. An asynchronous HEAD read that fails or yields
no commit now marks that amend message as unavailable and keeps Commit disabled.
The unrelated normal draft is retained for recovery, but is not silently treated
as an accepted amend message. Turning Amend off restores that draft; turning it
on retries through the same existing checkbox rather than adding another option.
A failed attempt cannot populate the amend-draft cache with the normal text.

Successful reads preserve the existing byte-exact draft-edit policy, cached amend
edits, message focus and author/date refreshes. Cancellation, generation and
window ownership checks reject a late reply after the user has returned to the
normal draft. Actual metadata operations remain counted until the reader returns.
Forced Rebase Split/Edit and History Combine presets clear failure state through
their existing metadata invalidation path; their supplied messages and APIs remain
unchanged.

## Related native children and inherited presentation

The Commit message/hash revision picker now receives the Commit window's own
preferences. The actual History, revision-picker and commit-progress sheets
receive the parent's alpha value and appearance before presentation. This keeps
private automated owners and their children invisible and preserves the user's
own view settings through these message/commit handoffs. Repository-level
Commit → Push/Pull/Create Tag follow-ups inherit the originating preferences
through the parent's separately owned integration.

## Stable option transitions — October 28, 2026

The native Commit form handles Amend, Show diff to last commit, Set author and
Set author date through both immediate menu/checkbox actions and deferred view
observers. The first action must start the transition before returning, so a
following focus or Commit command sees the accepted metadata/loading state.
Repeated observers of that same accepted option must not restart its read,
replace a prepared author/date draft or invalidate newly admitted form focus.

The previous suppression entry was a Boolean removed by the first observer.
Another observer for the same unchanged value could therefore repeat the
transition. Each actual option-value mutation now receives a separate identity;
the corresponding handler acknowledges it before publishing loading/draft
changes. The acknowledgement persists for that unchanged value, including
coalesced off/on changes, so another view callback has no new transition to run.
A genuine later toggle receives a fresh identity. Explicit metadata refreshes
from Amend, identity preparation or a replay preset still run intentionally and
acknowledge their current option. Post-Commit resets keep their existing
no-reread markers, and invalidation clears the owner's transition identities.

This preserves the source's synchronous checkbox behavior while adapting to
SwiftUI's delayed observation. The source anchors remain
`CommitDlg.cpp::OnBnClickedCommitAmend`,
`OnBnClickedCommitAmenddiff`, `OnBnClickedCommitSetauthor` and
`OnBnClickedCommitSetDateTime`. Current/HEAD defaults, read-only author behavior,
separate date/time controls, Reset and real Git options retain their existing
implementation. No new control or Core Commit operation is added by this repair.

The [official hosted excerpt](qa/ci-commit-date-form-eabf99f9-2026-10-28.txt)
records run `40565912425`, job `122414076064`, head
`eabf99f902644ec8ba8cb2295a4d904a111bfc35`, failing in the first primary Commit
receiver with “Delayed date view callback retired the accepted option form”.
That failure remains distinct from earlier focused passes. The new
[grouped checkpoint](qa/commit-form-lifecycle-2026-10-28.json) records the
actual repair validation; authored assertions alone are not a pass. It does not
certify every Commit source state, the complete hosted job or a new signed
installation.

The [October 28 checkpoint](qa/commit-form-lifecycle-2026-10-28.json) records
six native case/engine pairs passing cumulatively: primary options, metadata
lifetime and real ReCommit editing with system and bundled Git. The original
ReCommit fixture omitted native readiness after successful reset; its repaired
checks captured the new model/session while the actual editor was still disabled,
then waited for real input admission before retaining exact text/Undo assertions.
A diagnostic actor-isolation compilation failure is recorded too. All seven
attempted receivers were reaped and independently absent. The unsigned Debug
build passed; Core was unchanged and its full suite was not rerun locally.

## Grouped validation and remaining scope

`docs/qa/commit-option-transition-native-2026-10-18.swift` exercises the production
native classic/staging probes and callbacks, source Message-only commit/list/drop
separation, captured menu retirement across away/back transitions, unchanged staged
index bytes before Commit, actual hidden private Log picker and progress sheets, metadata model
failure/retry/draft/late-read accounting, and a real message-only amend that
preserves HEAD's tree and working inputs while applying the source's classic
in-scope index normalization. Merely toggling options preserves the original
staged patch; the actual classic Message-only commit treats displayed rows as
unchecked, resetting their tracked modifications in the index to HEAD. Existing
checkbox-index restoration policies govern additions, deletions and renames;
staging mode retains its distinct whole-index commit behavior. Injected metadata
failures use the production model without a view so diagnostic sheets do not
interrupt the desktop. Cleanup resumes held readers, retires owned models, closes
all windows and waits for actual worker counters, including picker history reads.
The parent records the grouped check results; fixture existence is not a pass.

No Core Git implementation changed in this continuation. Existing focused
CommitSelection/CommitAmend checks remain relevant to the real commit assertions;
a full Core rerun is not implied by native-only transition changes.

Remaining scope includes physical keyboard/default-button and VoiceOver
acceptance, full upstream Commit state/layout comparison, interactive signing/
hooks/provider failures, every staging/amend/operation combination, signed access
and complete source patch-mode behavior. AppKit disabled-list and inherited-sheet
checks do not establish every upstream dialog or whole-port completion.

## Native option routes and retained choices — October 28, 2026

The later hosted Commit failure (`40709146937`, primary options assertion 173)
exposed a separate dispatch defect: the native Amend menu changed the Boolean
directly, while the checkbox entered the receipt-owned handler synchronously.
The observer could arrive after a caller had already mistaken the form for a
settled Amend state. Earlier observer-identity checks did not remove that native
menu bypass.

This related batch aligns the eleven menu options with the same form admission,
checked state and mutation boundary used by the controls: Amend, amend comparison,
author/date/reset, new branch, staging, unversioned visibility, whole project,
message only and submodule autoselection. Repeated unchanged values must preserve
the user's current file inclusion and manually rechecked submodule choices.
Staging admission reflects whether its initial preferences have loaded. Explicit
metadata retry/read handlers retain their separate purpose.

Sign-off button and menu admission also belong to the current owned form and its
modal/readiness checks, with their existing Git identity, trailer, cancellation
and worker-drain behavior retained. This is a route and ownership correction;
new source checkboxes or different Git Commit semantics are not required.

The [grouped native checkpoint](qa/commit-option-workflow-2026-10-28.json) passes
with system and bundled Git. The default fixture exercises actual menu dispatch and the shared form
handler while HEAD metadata is held, alongside retained file choices and existing
author/date/branch/submodule/ownership cases. The invisible SwiftUI receiver does
not expose its checkbox as an actionable public accessibility element; attempted
native-control discovery remains recorded as unavailable, not a passed checkbox
interaction. An explicit acceptance mode retains that actual-action requirement.
Physical checkbox acceptance, a complete hosted run and newly installed source
remain separate gates.

The [installed build27 checkpoint](qa/signed-consolidation-build27-2026-10-28.json)
separately verifies actual Amend checkbox action in both Git Gui and Classic:
checking loads HEAD metadata, unchecking restores the original empty draft, and
the original presentation is restored. No commit was submitted. This is basic
physical acceptance, not the invisible receiver's opt-in mode or every option
combination. A manual native-menu attempt hit stale accessibility targets and
was not accepted as a pass; an automation-only test character was removed through
normal editor input before closing, without accepting the history-save question.
