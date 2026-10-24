# Optional comparison and commit interfaces

Classic remains the default for both workflows. The saved application preferences
are `TurtleGit.Comparison.CurvedInterface` and `TurtleGit.Commit.GitGuiInterface`.
The comparison preference is shared by two-file and three-way text windows;
changing it does not replace the document or save a file. Commit's alternative
workspace uses the existing Git index and partial-patch backend, with an owned
embedded patch model retired when its window closes or interface changes.

## Source comparison

Pinned TortoiseGit baseline: `7338078f8ddd924b8cddee35f512f2286072136d`.
`src/TortoiseMerge/MainFrm.cpp::OnCreateClient` constructs the classic upper
source panes and lower result pane. That layout remains available.
`src/Resources/TortoiseProcENG.rc::IDD_COMMITDLG` and
`src/TortoiseProc/CommitDlg.cpp` retain the source's single-list staging toggle
and checked-file commit behavior in Classic. The new interfaces are intentional
Mac alternatives, not claims of additional upstream dialog parity.

The alternative Commit workspace reuses source status artwork, separate index
and working-tree snapshots, stale-patch checks, serial repository operations,
identity/hooks/preflight and owned progress. It shows staged and unstaged lists,
whole-file Stage/Unstage, line/chunk actions, message and Amend. It does not copy
Git Gui's menu system. Classic-only options remain accessible by switching back.

## Remaining behavior and acceptance

- P4Merge-style is a presentation choice; it does not reproduce every Perforce
  toolbar, gesture, theme or four-pane layout.
- Curved merge connectors require an exact aligned result projection. Arbitrary
  manual rewrites and multi-copy choices can invalidate that projection; those
  connectors are then omitted rather than pointing at unrelated result lines.
- Full physical keyboard, VoiceOver, multi-display resizing and signed App Store
  acceptance remain open. A local build and focused receiver pass do not prove
  those checks or hosted CI.
- Issue-provider, author/date and branch options use Classic; the alternative
  intentionally presents a smaller set of commit controls.

See [getting started](GETTING-STARTED.md) and [merge tool](MERGE-TOOL.md) for use.
