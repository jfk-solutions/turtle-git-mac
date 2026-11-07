# Submodule acceptance, results and native ownership

Source comparison: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`SubmoduleAddDlg.cpp` (`IDD_SUBMODULE_ADD`), `SubmoduleUpdateDlg.cpp`
(`IDD_SUBMODULE_UPDATE`), `SubmoduleDiffDlg.cpp` (`IDD_DIFFSUBMODULE`),
`SubmoduleResolveConflictDlg.cpp` (`IDD_RESOLVESUBMODULECONFLICT`) and
`Commands/SubmoduleCommand.cpp`. This is a partial workflow audit, supplementing
the existing Add, Update, Sync, Diff and Conflict parity records.

## Implemented batch, 7 November 2026

- Add uses the repository-aware window title. Its native repository, destination
  and SSH-key choosers start from the reviewed field or its nearest existing
  parent, rather than Recents. Picker results remain fenced until the actual
  sheet detaches, and cannot replace fields changed while the chooser was open.
- Add submission and directly opened progress commands capture the owning Git
  backend before suspension; an explicitly inherited configuration is retained.
  Conflict resolution captures that policy before confirmation. Its owned Reset
  child and continuation retain the same executable, askpass, diff policy and
  backend instead of reconstructing a default repository.
- Add progress distinguishes checkout-verification failure from SSH-key
  configuration failure. Partial addition no longer receives a success footer.
  Retired progress cannot publish a late outcome into its closed form, while
  the captured attempted-operation callback still receives the actual receipt.
- Update publishes its immutable attempted result before optional Bisect
  discovery. That read has separate cancellation and a bounded deadline;
  cancelling it or closing its window cannot reclassify an accepted update.
  Progress stays complete during discovery. Confirmation targets the exact
  phase that was reviewed, so a late reply cannot cancel a subsequent phase.
- Update and Sync retain typed result status even when cancellation arrives
  after the command has finished. Captured refresh callbacks survive retirement.
- Add, Update, Sync, Diff and Conflict controllers retain their presenting sheet
  relationship until physical detachment, including forced closure, before
  reporting workflow release. Existing child work and helper drainage remain
  part of that condition.

The source's Update option defaults, selection controls, immediate Whole Project
preference, Add histories and branch/force options remain in their existing
implementations; this batch does not claim a new complete control audit.

## Validation and remaining scope

The [coordinated Stash/Submodule checkpoint](qa/stash-submodule-recovery-2026-11-07.json)
records 40 Core cases and 34 native case/engine pairs passing cumulatively. The
initial native pass and focused repairs remain separately recorded. Native cases
cover existing receipts, actual Git actions, held native chooser detachment,
forced closure and backend changes during confirmation. No unaffected cases were
repeated after their pass.

Complete visual comparison of every upstream control, physical keyboard and
VoiceOver acceptance, real SSH/network server behavior, filesystem-dependent
Unicode checkout limits, signed sandbox/Finder deployment and hosted CI remain
separate acceptance work. These resource IDs identify reviewed workflows, not
fully certified dialogs or a completion percentage for the port.
