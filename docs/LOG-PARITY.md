# Log Messages parity

The implementation target is the actual TortoiseGit Log Messages dialog and its
selection-dependent context menus. Native macOS controls retain the three-pane
arrangement and familiar command order. The initial sidebar log table was removed.

## Specification

Audited baseline: `7338078f8ddd924b8cddee35f512f2286072136d`.

- `src/Resources/TortoiseProcENG.rc`, `IDD_LOGMESSAGE`: filter row, three panes,
  path filter, project/all-branches toggles and footer controls.
- `src/TortoiseProc/LogDlg.cpp` and `LogDlg.h`: selection, changed files and controls.
- `src/TortoiseProc/GitLogListBase.cpp`: columns, graph painting and revision menus.
- `src/TortoiseProc/GitLogListAction.cpp`: revision operations.
- [Upstream Log Messages manual](https://tortoisegit.org/docs/tortoisegit/tgit-dug-showlog.html).

## Implemented and checked

- Separate resizable native window with three resizable panes.
- Compact graph before SHA-1/message/author/date; continuous lanes based on real
  parent hashes. Circles mark ordinary commits, squares mark merges/branch points.
  Topological order avoids sorting rows into a misleading graph.
- HEAD in bold; active branch red, other local branches green, remote branches
  orange and annotated/lightweight tags yellow.
- Full selected commit message, hash, author/email, date and parents.
- Changed paths, extension, action, added/removed counts; binary counts are `–`.
  Root commits and merge first-parent changes are handled explicitly. NUL parsing
  preserves tabs, newlines and Unicode filenames and both sides of a rename.
- Case-insensitive fixed-string commit-message search, optional date range,
  all branches, path filtering in the changed-file pane and loading 200 more rows.
- Single-revision/base and working-tree unified diff; two-revision unified diff.
  Double-click a revision opens the comparison. Patch text remains selectable.
- Hash, message and log-details copy actions; changed-path copy and comparisons.
- Branch and lightweight tag creation at a selected hash, detached checkout,
  soft/mixed/hard reset, revert without committing, and single-parent cherry-pick.
  Each operation opens a native dialog capturing the exact selected revision.
- Original upstream colored command icons in revision and changed-file menus.

Tests cover graph continuity at merges and branch points, octopus/disconnected
histories, real root/merge/rename stats, binary and unusual paths, full commit
messages, annotated tags, search and limits. Native preview QA checked selection,
merge graph, file stats and double-click diff with disposable sample repositories.

## Still partial

| Area | Remaining behavior |
| --- | --- |
| Columns | Actions icons, column chooser/persistence, optional email/committer/bug/SVN columns |
| Graph | Working-tree pseudo revision, collapse/expand, hidden refs and all merge parent choices |
| References | Branch/ref chooser, remote ref deletion and tracking menus |
| Search/filter | Author/email/hash/path search modes, jump next/previous, whole-project/folder history, regex and highlighting |
| Files | Multi-revision union, multi-file diff, file log/blame, restore, save/export revision, open/editor/Finder actions |
| Revision menus | Repository browser, rebase onto selection, edit notes, export, format patch, bisect, squash, ref containment/search |
| Mutations | Full branch/tag options, checkout branches, mainline choices for merge revert/cherry-pick, multi-commit operations, conflict continue/abort |
| Footer | Statistics, walk behavior, View options and upstream settings persistence |
| Comparison | Native side-by-side/three-way editor, merge combined diffs and external tool configuration |
| Accessibility | Full VoiceOver acceptance, keyboard shortcuts and focus parity |

These source mappings remain partial. A populated menu or a working Git command
does not establish complete upstream parity.

## Icon provenance

Artwork is copied unchanged from the pinned upstream resource directory. The
shared `Icons` resource folder contains the original license and a source-path and
SHA-256 manifest. We choose its GPL alternative. Both Xcode's shared framework and
Swift Package resources carry the artwork. AppKit reads the multi-resolution ICO
and renders 16-point colored menu icons, without template tinting for colored artwork. The monochrome cherry-pick glyph
uses native template tinting for light/dark contrast. Finder uses
upstream XPStyle status artwork; signed Finder visual QA remains pending.

Finder file/folder requests now scope history to all selected paths. The native
Show Whole Project checkbox removes that scope; reopening Show Log from Finder
restores the requested selection. Requests for the repository root show its full
history. The full upstream folder-history controls and rename-following history
remain pending.

Push from a single log revision now opens the separate native Push options window
with that exact hash and the original Push icon. The window builds successfully;
this specific Log handoff still needs native interaction QA. See PUSH-PARITY.md.
