# Editor Save, history and native readiness

This connected review uses TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`, especially TortoiseMerge's
`MainFrm.cpp` Save/MarkAsOriginal and Undo routes, `CUndo`, and
`BaseView.cpp::SetTextType`. It is a partial workflow review, not certification
of every Compare or Merge state.

## Save and current editing ownership

A completed Save restores the current native editor's writable state before its
completion callback runs. Undo, Redo, source/block choices, format commands,
typing, clipboard and Find replacement use current pane ownership and current
document presentation. A queued native update is not the authority for deciding
whether the document can now be edited. Busy operations, owned choices, Quit,
read-only documents and retired or replaced panes retain their existing gates.

The original hosted source-block timeout showed an unchanged result after a
single immediate post-Save Undo. The retained receiver now dispatches Undo from
the actual Save completion and records native editing readiness as well as exact
saved bytes. It does not hide the boundary with another layout-settlement wait.

## Document history across layouts

Merge history belongs to the loaded document. Its records retain result text,
source comparison, row annotations/choices, encoding, line endings and serialized
caret position. Restoration resolves the currently owned result pane, so an
action recorded in Classic can be undone in the P4Merge-style interface and
vice versa. Replacing a native pane retires its delegates, Find and callbacks
without clearing document history. Accepted reload and document retirement still
clear that history.

Compare retains its existing document-wide ordered history across both panes.
Save and Save As update the accepted output baseline without putting the output
target into a restorable edit snapshot. Undo must not retarget a saved copy or
roll back the fact that a file was successfully written. Cancelled or failed
Save As preserves the prior target, draft and history.

## Format transactions

Compare's history now includes the output codec. A combined format operation
validates its new encoding before applying text/line-ending and codec changes as
one transaction; Undo/Redo restores them together. Encoding-only Undo is a native
consistency adaptation: pinned `SetTextType` marks the document modified without
separately registering a codec Undo operation.

A captured historical draft can contain text that its old codec cannot save.
Restoring that exact history state retains the text and codec without rolling
back saved baselines. New format choices and Save/export still perform their
ordinary lossless encoding checks. The narrow Core restoration API does not
enable editing for read-only panes.

## Validation and remaining work

The grouped checkpoint covers actual native Compare and Merge in both layouts,
immediate completion dispatch, format history, pane replacement, read-only/Quit
and closed-owner refusal, Save As cancellation/failure/retry, and the retained
ordinary source-block and Save As workflows. Private repositories, preferences,
pasteboards, invisible windows and cached production app linkage bound it.
Actual results and any failed attempts are recorded with the batch checkpoint.

The related Clone correction applies clipboard/history-derived repository names
after the launch's exact-path policy is known; see [Clone parity](CLONE-PARITY.md).
Full corrected-source hosted integration, signed/physical workflows, receiving
applications, VoiceOver, Intel/minimum macOS and complete upstream layout/state
acceptance remain separate. The installed application is not updated by a local
Debug build or these focused checks.

The [actual checkpoint](qa/editor-clone-save-history-2026-11-22.json) passes three
focused Core methods, the app build and fourteen native case/engine pairs after
recorded fixture repairs. Previously passing Core, build and native groups were
retained. The built Help manifest matches the current generated guides; resource
checks and all 22 logged owned-process absence checks are recorded separately.
