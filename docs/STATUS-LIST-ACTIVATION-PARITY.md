# File-list primary activation

This family follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`.
`src/Git/GitStatusListCtrl.cpp::OnNMDblclk` selects its operation from the
notification's activated row. Checkbox-state icons and invalid rows do not open
viewers. A conflicted row opens conflict editing; ordinary rows use the existing
status/revision comparison policy. This differs from an explicit context-menu
command that deliberately acts on a complete selected set.

The native SwiftUI Table primary action supplies selected IDs. Using that set
as the double-click target made multi-selected Classic Commit rows open several
comparisons and could bypass conflict editing for the clicked row. The shared
status-list bridge captures row activation independently from highlighted rows,
with content/owner validation and invocation modifiers. Normal selection,
checked-file membership, menu snapshots and deliberate multi-file commands retain
their existing ownership.

The related Repository Browser source has its own distinction:
`RepositoryBrowser.cpp::OnNMDblclk_RepoList` activates the clicked item, while
`OnOK` requires one selected item when the contents list owns Return. The native
contents table must retain that distinction for file, directory and submodule
routes. Its footer also keeps the source's two-line information text inside a
stable layout: `IDD_REPOSITORY_BROWSER / IDC_INFOLABEL` is a fixed rectangle,
not a label whose height changes when selection changes.

This is a connected implementation record, not complete certification of Commit,
Check for Modifications, Resolve or Repository Browser. Native event/selection,
comparison/conflict handoff, ownership and layout evidence is recorded at the
[batch checkpoint](qa/file-activation-sync-options-2026-10-30.json).
The status-list receiver passes with both Git engines, including mounted
checkbox actions, multi-selected conflict intent, captured Shift and stale
sort/reload/closed receipts. The Browser activation/presentation/lifecycle groups
also pass with both engines; its invisible native mouse tracker uses scoped
public key-state injection, not desktop activation. Physical pointer/keyboard/VoiceOver, signed external grants,
full source appearance and whole-port acceptance remain separate.
