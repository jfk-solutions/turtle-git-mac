# Rebase revision menu family — October 18, 2026

Reference: pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseProc/GitLogListBase.cpp::OnContextMenu`,
`GitLogListAction.cpp::SetSelectedRebaseAction` and
`RebaseDlg.cpp::SetControlEnable`, with `src/Resources/TortoiseProcENG.rc` /
`IDD_REBASE`.

The native replay table now inserts action commands in source order: Pick,
Squash, Edit, Skip. The oldest visible occurrence, or any selection including
it, omits Squash. An ordinary merge at the first selected occurrence omits
Squash; Cherry Pick retains the source exception. Current/completed marked
occurrences do not expose draft action commands, and the setter preserves those
rows even if they appear in a choosing draft. Source action icons and the private
Show app context-menu icons preference apply throughout nested menus.

The existing comparison family now includes every merge parent, plus All Parents,
Only Merged Files, Show extra changes after merge and each individual unified
parent mode. These use the existing real Git readers and comparison presentation,
with captured canonical parent hashes and Shift/alternate-tool state. Single
parent entries retain the direct commands; root commits omit the source previous
comparison/unified entries. Two revisions retain their existing comparison.
The previous-revision item and first parent receive native bold emphasis when
DiffByDoubleClickInLog is enabled. Return and double-click use that preference;
other action keys and drag ordering retain their existing behavior.

Right-click selects an unselected pointed row and refuses blank list space.
Shift F10 and accessibility Show Menu open the selected-row popup, scrolling its
first occurrence into view. A captured menu may run once. Its occurrence order,
actions/progress, selection, form generation, phase, consumer policy and parent
window must remain current. Selection/options away-and-back, a new menu,
reference picker, replay question, child sheet, Quit, busy or retired owner refuse
late callbacks before they can change a plan or open a comparison. Submenus
share the same receipt. These policies are window-local, not global preferences.

The hidden [native fixture](qa/rebase-revision-menu-native-2026-10-18.swift)
uses private real merge history and preference suites. It compares all five
unified modes with actual Git bytes, verifies second-parent/alternate routing,
action/current/done/oldest/merge rules, default emphasis, icon inheritance,
keyboard/AX entry and stale/Quit/retired callbacks. Retained native bulk/completion
controls and row-drag/structural replay cases share the checkpoint. Actual results
are recorded in [batch evidence](qa/rebase-revision-menus-2026-10-18.json).

The [durable pending action family](REBASE-PENDING-ACTIONS-PARITY.md) supersedes
the earlier paused-session editing gap for reproducible native sessions. It owns
the saved todo/identity/message transaction; the menu does not edit live files
by itself. Older/custom structural conversion remains explicit.
The connected [history tools family](REBASE-HISTORY-TOOLS-PARITY.md) adds
Find, Export, containing references and all three range Log entries. The
[reference-context continuation](REBASE-REFERENCE-CONTEXT-PARITY.md) connects
pointed labels and additional applicable shared Log actions. Exhaustive consumer
state combinations remain open. No compiled Windows enabled/omitted matrix, physical
pointer/VoiceOver, minimum-macOS/Intel, signed deployment or full-dialog visual
parity is certified by this batch. The complete port remains unfinished.
