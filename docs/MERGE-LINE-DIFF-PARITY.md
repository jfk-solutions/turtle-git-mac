# Merge Line Diff Bar

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseMerge/LineDiffBar.cpp`, `BaseView.cpp::ShowDiffLines`, and
`MainFrm.cpp` (`LineDiff` defaults to true).

The two-pane text comparison has a saved **Line diff bar** checkbox. Below the
panes it displays Base above Mine, following the pointer over an aligned line.
Caret selection also updates the preview. The strip uses the same font, tab
widths and colored source palettes as the panes. It always displays whitespace
and inline changes, independent of the main-pane toggles; original endings use
the selected shape/icon setting. Word mode and the general inline length bound
still apply. Missing-character ticks are drawn without inserting characters.
Each preview line follows its pane's horizontal scroll position.

The strip is read-only and does not become first responder or change selection,
Undo, text, staging or disk. Mouse exit, invalid rows, alignment rebuild and
window retirement clear it. Single-file comparisons suppress it; three-pane
merge windows do not display the bar, matching the source's ordinary layout.

Native verification is included in the existing grouped Merge and LFS/mail
receivers. It covers persistence, pointer-to-row mapping with UTF-16 text,
forced whitespace/inline rendering, changed CRLF, light/dark drawing and
selection/history/file invariants, plus exit/rebuild/retirement guards.

Remaining: physical pointer/keyboard/VoiceOver and minimum-size acceptance,
Windows docking/layout fidelity, exceptional three-pane bar visibility,
line-number margin parity, and libsvn repeated-token inline tie behavior.
Screenshots from focused rendering are QA evidence, not whole-window acceptance.
