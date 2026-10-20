# Synchronization incoming and outgoing commit lists

This partial family review follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`, `IDD_SYNC`,
`SyncDlg.cpp`, `GitLogListBase.cpp`, `GitLogListAction.cpp` and
`ColumnManager.{cpp,h}`. It covers the In Commits and Out Commits tables,
their native menus and connected revision actions. The grouped checkpoint below
covers this family; this document does not certify the full dialog.

## Source behavior

`SyncDlg` creates separate `SyncIn` and `SyncOut` log lists, both using
`InsertGitColumn`. Graph, Actions, Message, Author and Date are initially shown;
SHA-1, Email and committer columns are initially hidden. Bug-ID availability
follows project properties. SVN revision availability and default visibility
follow `CTGitPath::HasGitSVNDir`, which checks the resolved administrative
`svn/.metadata` marker. Revision extraction follows the pinned `FindSVNRev`
patterns through the existing native IssueRegex runtime. Those patterns use
whole-message anchors: an ordinary subject followed by a git-svn-id trailer
returns no revision in this pinned implementation. The native list retains that
behavior; column availability does not imply every SVN trailer yields a number.

Header visibility items exclude the first Graph column (`ColumnManager.h`,
`AddMenuItem`). Reset column order asks Yes/No before restoring natural order,
default visibility and widths. Unlike the reference/tag result tables, commit
list reset measures row text as well as headers (`ColumnManager::GetWidth`);
long messages must not be reduced to a header-only width. Incoming and outgoing layouts belong to their
separate source identities and captured preference stores.

The configured Log font is consumed only when LogFontForLogCtrl is enabled.
The source also installs a small-icon minimum row height. Native rows must fit
the configured regular/bold/italic font and graph/action icons without clipping.

Return and double-click use the first parent when DiffByDoubleClickInLog is
enabled. A root commit presents “No previous version.” (`GitLogListAction`,
ID_COMPAREWITHPREVIOUS), rather than silently doing nothing. Shift retains the
alternate comparison-tool choice. These behaviors share the existing comparison
and revision-operation consumers rather than adding different Git operations.

## Native ownership requirements

A native menu must retain its table, selected revision occurrence(s), source tab
and result generation until one action claims it. Replacing results, changing
selection/tab, reading, Quit, an attached sheet or closure must prevent retained
row/header callbacks from acting on another result or preference identity.
Parent-caption and ancestry reads must cancel and drain with their owner.
Column reset and root feedback must retain their native sheet ownership through
actual detachment, including closure and late replies. Physical menu tracking,
VoiceOver, all locale/layout combinations, signed grants and complete source
acceptance remain separate gates.

## Connected implementation and checkpoint — October 21, 2026

`SynchronizationCommitList` retains its source side and selected row occurrences
through one-use menus, including lazy parent-caption updates. Dismantling the
native view retires row/header menus and keyboard callbacks. Log metadata and
comparison/clipboard workers remain owned until their actual completion after
cancellation. Root and reset sheets retain the parent Quit fence through actual
detachment. History comparisons pass both captured Shift choice and originating
preferences to the configured comparison window. The shared Return dispatcher
supplies its event's Shift state without changing Find/default-key routing.

Explicit width/order layouts belong to the captured preference store and side.
When no explicit layout exists, the standard application store alone imports its
previous AppKit autosave layout once, then disables legacy autosave. Existing
visibility preferences remain consumers. Actual installed legacy migration has
static peer review, while the native receiver uses private preference stores.

The Debug app and four native case/engine combinations pass with system and
bundled Git. The first receiver found an incorrect fixture expectation for SVN
trailers; matching the pinned helper fixed the fixture without changing the app
or repeating its build. No native cases had passed before that correction. Core
was unchanged. All three owned receivers are independently absent.
[Evidence](qa/sync-history-controls-2026-10-21.json) records the checks and limits.

Reviewed [outgoing light](site/assets/sync-outgoing-commits-light.png) and
[dark](site/assets/sync-outgoing-commits-dark.png), and
[incoming light](site/assets/sync-incoming-commits-light.png) and
[dark](site/assets/sync-incoming-commits-dark.png) captures use the configured
Menlo 24-point Log font to exercise larger rows. Offscreen columns remain
reachable by horizontal scrolling. They do not certify default-size Windows
pixel parity or physical input/VoiceOver/signed acceptance.
