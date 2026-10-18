# Captured Settings sheet handoffs — October 18, 2026

This connected native repair covers Rebase identity repair, Git Properties →
Settings and Unified Diff → Settings. Reference source is pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`:

- `src/TortoiseProc/RebaseDlg.cpp::CheckRebaseCondition` and
  `src/TortoiseProc/AppUtils.cpp::CheckUserData`: repair identity before replay.
- `src/TortoiseShell/GITPropertyPage.cpp`, `IDC_SHOWSETTINGS`: open Settings with
  the captured project root. This action does not automatically refresh index
  flags or discard an existing property draft.
- `src/TortoiseUDiff/MainWindow.cpp`: launch `/command:settings /page:udiff`.

Windows launches separate processes. The native adaptation uses an owned sheet
with the same Settings pages, captured preferences and permission context.
`SettingsSheetController` shares the guarded close policy across these callers.
AppKit disables an attached sheet's title-bar close button, so ordinary
`performClose` can silently reject Settings footer OK/Cancel. The native sheet
accepts explicit close only while the transaction and delegate permit it.
An applying transaction continues to refuse closure and Quit. Ownership lasts
through actual AppKit sheet detachment; late callbacks cannot revive a retired
owner. Child presentation inherits its owner's alpha, including invisible QA.

Git Properties keeps its selected repository/access and its unapplied index-flag
draft. It now passes the original preferences to Settings, including appearance.
Unified Diff starts on its global Unified Diff page, retains its dirty text and
queues replacement documents while Settings is open. After actual detachment,
the existing Save/Discard/Cancel workflow resolves the replacement. Cancelling
that question preserves the original document. Forced parent retirement rejects
queued publication. Rebase retains its existing identity reread and repair loop.

The [native fixture](qa/settings-sheet-family-native-2026-10-18.swift) dispatches
real footer actions, explicit Close, held-save refusal, private preference reads,
property draft preservation, dirty/replacement decisions, Quit refusal and forced
retirement. Retained Rebase, Properties and document workflows share the grouped
checkpoint. [Evidence](qa/settings-sheets-2026-10-18.json) records actual results;
fixture existence alone does not establish a pass.

Remaining: physical mouse/keyboard and VoiceOver acceptance, minimum macOS and
hosted Intel SDK execution, signed permission leases, complete visual comparison
of Settings pages and full application parity. The Remote list repair is recorded
in the [preceding batch](qa/history-actions-2026-10-18.json); this sheet family
makes no additional claim about every remote interaction or upstream dialog.
