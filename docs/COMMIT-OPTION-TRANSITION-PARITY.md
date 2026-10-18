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
