# Primary dialog visual review — 14 October 2026

The current native Commit, staging-mode Commit, Log and Working Tree windows
were captured in light and dark appearance from a private repository. These are
unaltered macOS compositor captures, including window chrome. The reference is
TortoiseGit commit `7338078f8ddd924b8cddee35f512f2286072136d`, its
`doc/images/en/Commit.png` and `LogMessages.png`, and the `IDD_COMMITDLG`,
Log and `IDD_CHANGEDFILES` resources in `src/Resources/TortoiseProcENG.rc`.

| Window | Source arrangement retained | Differences and remaining review |
| --- | --- | --- |
| Commit | Branch destination, message above changes, amend/date/author options, category links, lower checkbox groups and Commit split actions | Native title bar, rounded controls and fonts differ. All conditional states, minimum sizes, keyboard and VoiceOver still need acceptance. |
| Staging | Same file list with three-state checkboxes; separate partial staging/unstaging controls | This capture shows an existing mixed index/worktree state; it does not exercise applying lines or hunks. Physical attached-window placement remains open. |
| Log | Small graph before revision text, colored references, message pane, changed files grouped by merge parent, five changed-file columns | Fixed All Branches checkbox intrinsic sizing so the footer stays compact. All graph topologies, filter combinations and physical resizing remain open. |
| Working Tree | Branch destination, colored file rows, status/changelist groups, lower filters and Save unified diff/Stash/Commit/Refresh/OK actions | Native row spacing and controls differ. Complete conditional menus, physical input and signed scope behavior remain open. |

Eight main-window captures replace the current general gallery views. The older
partial-staging and operation-specific captures remain with their existing
acceptance descriptions. Two new partial-staging diagnostics were excluded:
the compositor produced inconsistent parent/child grouping and activation. They
do not establish a production alignment defect or certify right-hand placement.

The fixture preserved HEAD, logical index tree and porcelain working-tree status,
closed its windows and reaped its receiver. Four grouped native Log regression
cases passed with system and bundled Git. Core was unchanged and was not retested.
An initial fixture compile failure was repaired; a first visual pass found the
footer sizing defect, which was corrected before final capture. No additional
validation is warranted by the documentation-only changes after those passes.

[Recorded results and image hashes](qa/primary-dialog-visual-2026-10-14.json).
The whole port, complete hosted CI, signed Finder integration and full physical
visual/accessibility parity remain incomplete.


The connected preview/viewport follow-up supplies current unaltered Partial
Staging captures in both appearances. The preview is a controller-owned modeless
companion, with native screen placement and sticky edges, so its own compositor
capture no longer contains the preceding parent/child gap. Both images show the
complete colored patch. Independent captures do not certify physical adjacent
placement or all scrolling/keyboard behavior. Six unique native workflow cases
passed; see [results and remaining work](qa/preview-viewport-2026-10-14.json).

![Current light Partial Staging window](site/assets/partial-staging-current-light.png)

![Current dark Partial Staging window](site/assets/partial-staging-current-dark.png)

The October 15 [Log filter/layout batch](LOG-FILTER-PARITY.md) supersedes the
older Log header/footer captures with an integrated native filter menu and source
command rows. Its light/dark compositor captures were reviewed after correcting
From compression and ordinary/selector footer differences. Complete source and
physical/signed acceptance remain open.

The later October 15 [scope/information batch](LOG-FOOTER-PARITY.md) adds the
permanent Whole Project checkbox and full source information line. Its current
light/dark captures retain the earlier filter/header arrangement. Dark rename-row
contrast remains open and is not certified by these captures.
