# Rebase history tools family — October 18, 2026

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
Source references are `GitLogListBase.cpp::OnContextMenu` and
`OnFindDialogMessage`, `GitLogListAction.cpp` (Export, containing references and
range logs), `RebaseDlg.cpp::OnLvnItemchangedLoglist`, `FindDlg.cpp`,
`CommitIsOnRefsDlg.cpp`, `IDD_REBASE`, `IDD_COMMITISONREFS` and the shared
`IDD_FIND` resource.

The replay table connects the shared native Find dialog, Export this version,
Show branches this commit is on and all three two-revision Log ranges. Find keeps
an occurrence index, so repeated Cherry Pick entries remain distinct even when
hashes match. Text Find advances after the selection mark and wraps. Shift Find
scrolls without changing selection and italicizes matching hashes. Ordinary
native selection clears the emphasis. Reference navigation uses the first displayed
matching occurrence. Search history, regex/case options, reference filtering and
source artwork reuse the existing native Find implementation.

Export reuses the existing native Export workflow and source tag preference.
The existing owned column-metadata read also loads the peeled reference map;
menus and Find receive real decorations without starting Git from a popup.
Find reads changed paths from Git instead of borrowing asynchronously refreshed
selection details that might belong to a different row.
Forward, reverse and symmetric Log ranges capture canonical row hashes and retain
the parent repository, access lease and preferences. The containing-reference
window retains its existing revision chooser, filter, reference list, Log and
comparison actions. Source icons honor the app context-menu icon preference.
Menus use the replay table's existing single-use receipts and reject stale
selection, plan, phase, owner or consumer state.

Helper windows inherit the parent appearance and visibility before presentation.
Find error sheets and containing-reference pickers block parent actions and normal
close. Forced parent retirement closes its helpers, cancels reads and rejects late
navigation. Quit accounting and access leases survive until cancelled Git reads
actually return, including reads belonging to already closed windows.

The grouped runner is `scripts/test-rebase-history-tools.py`. It combines the new
[Rebase interaction fixture](qa/rebase-history-tools-native-2026-10-18.swift) with
retained Log Find, containing-reference, Export and replay-menu checks. Each case
uses a separate process and private repository/preferences. This batch changes
native consumers only; it does not require another full Core integration run.
Actual checkpoint results and limitations are recorded in
[batch evidence](qa/rebase-history-tools-2026-10-18.json).

Native status text replaces the source Windows flashing/beep feedback; font and
focus rendering follow AppKit.

The [reference context continuation](REBASE-REFERENCE-CONTEXT-PARITY.md) adds
pointed reference menus and further applicable shared Log actions. Remaining work
includes a compiled Windows enabled/omitted comparison, metadata changes
during a search and every mutation-to-Find refresh route. Physical mouse/keyboard
and VoiceOver acceptance, full dialog visual comparison, minimum macOS/Intel,
current hosted CI, signed sandbox/Finder deployment and App Store distribution
remain separate gates. This family does not certify the whole port.
