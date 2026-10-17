# Exact conflict paths in Resolve and Rebase

Source baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`Git.cpp` conflict/index readers, `ResolveDlg.cpp`, `RebaseDlg.cpp`, and
`GitStatusListCtrl.cpp::OnLvnItemchanged` / checked-path selection.

Git index path keys retain exact UTF-8 bytes. Swift String equality treats
canonical Unicode spellings as equal, so a normal dictionary can wrongly merge
their conflict stages. The shared NUL-delimited reader now groups stages with
exact keys, filters exact file/directory scopes and keeps an exact tie-break for
otherwise equivalent displayed paths. Conflict snapshots compare and hash exact
paths with their captured stages. Stage validation, specialized editor lookup
and selected-path deduplication use the same identity; a canonical neighbor
cannot supply another row's stages.

Resolve and Rebase conflict/recovery lists keep checked and highlighted raw paths
in separate exact sets. Their SwiftUI/AppKit row IDs encode each path as ASCII;
captions, clipboard and Git actions retain the raw text. Context menus, primary
actions, keyboard copy/Space and focused marks decode only at the native boundary.
Shared list callbacks already carry raw paths and retain their original order.
Independent check/highlight state survives refresh for the same live session;
new exact paths receive the existing default check policy.

Both lists now use the shared native binary file checkbox. Checking a highlighted
row applies the new state to the highlighted rows, as the pinned status list does.
Checking a row outside that highlight affects only that row. Busy, sheet, Quit,
recovery-mode and retired-owner gates remain authoritative. Captured menus retain
the original generation and exact snapshot; later reads cannot retarget a command.

Checked Rebase recovery passes exact paths through emptiness checks, private-index
Commit and the retained continuation snapshot. Stopped-session branch identity
and conflict-path comparisons are exact as well. The Git/index validation and
cancellation rules, original icons, columns, progress and owned children remain
part of the existing workflows.

The index may retain distinct names even when the host filesystem aliases them.
The fixtures do not establish two independent physical files on such volumes.
Arbitrary invalid UTF-8 paths, complete identity migration in other dialogs,
physical pointer/keyboard/VoiceOver, signed Finder and App Store acceptance remain
open. This is a connected conflict workflow change, not complete port certification.

## Checked recovery index preparation

The new real Rebase case exposed a second identity boundary: starting the private
commit index from HEAD and asking Git to discover two new canonical spellings
through an aliasing filesystem can add only the filesystem's spelling. Private
selection indexes now seed the checked stage-zero records from the real index
before the existing Git add. Only exact checked entries are copied; excluded
staged deletions retain their existing policy. Git add still reads current
whole-file contents and applies filters, with the existing staged-mode correction.
The shared emptiness/amend/checked-recovery backend uses this preparation path.
Unselected index contents, HEAD and working contents retain their existing owners.

## Grouped checkpoint

The [batch evidence](qa/conflict-path-identities-2026-10-18.json) records 148 distinct
Core cases passing across the initial 121-case run and its affected 35-case repair.
The first run exposed the private-index discovery loss described above; unaffected
Core cases were not repeated. Both Debug builds passed. All fourteen distinct
native case/engine combinations pass with system and bundled Git. The retained
fixture repairs adapt old Set/path-ID assertions to the new boundary without
removing their behavioral checks. All fifteen receivers, including the failed
retained fixture attempt, were reaped and independently absent.

The retained Resolve mutation checks still emit the known AppKit reentrant-table
delegate warning when entering shared Revert. This batch does not claim that
separate warning is repaired. Complete hosted/physical/signed acceptance remains
open, and the dialog ledger does not certify either complete dialog.
