# History, Browser and Export recovery

This connected continuation compares the native workflows with TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`. It addresses actual hosted failures
and related ownership gaps together; a receiver correction is distinguished from
an application repair.

## Browser navigation and delivered files

Refreshing a tree or choosing another folder must retire an outstanding stored
file read immediately. Its worker and access lease remain owned until the read
actually drains. A late reply cannot open an inspector, external application or
save panel for the replaced tree. Read cancellation does not grant navigation
during an active mutation or owned chooser. Directory and transfer inventory
reads keep the backend accepted with their tree snapshot.

An accepted Finder drag or file promise has a different lifetime: the receiver
may request its bytes after the Browser closes. Those transfers retain their
captured repository, tree and access rather than being cancelled with navigation.
Native drag admission requires a real current press over the exported row or
tree item. Tests must use that admission path instead of obsolete private
pasteboard-writer delegate methods.

The pinned source comparison remains `RepositoryBrowser.cpp`, including tree
navigation, refresh, file actions and drag handling. The separate
[filename contract](REPOSITORY-BROWSER-NAMESPACE-PARITY.md) retains unsupported
raw working-tree operations and original-name folder transfer boundaries.

## Log columns and containing references

The Graph column participates in the native column menu and persisted visibility
preference. Follow Renames temporarily suppresses it; leaving Follow restores the
user preference. Column commands retain the current owner and menu receipt.
The source references are `GitLogListBase.cpp` column definitions and
`ColumnManager.h`; the column definition's availability field must not be read as
a prohibition on changing visibility.

The containing-reference dialog retains the compact top revision/subject rows,
the right-aligned Show log button, bordered reference list and bottom filter.
Its native reference chooser, context commands and opened Log keep captured
ownership through actual child detachment. Forced close cancels owned reads and
waits for their drainage before reporting completion. Source behavior remains
`CommitIsOnRefsDlg.cpp`, `IDD_COMMITISONREFS` and the
[containing-reference contract](COMMIT-CONTAINING-REFS-PARITY.md).

Native font checks must host the actual Commit dialog so its SwiftUI preference
properties are installed. Calling a child-view factory on an uninstalled parent
does not establish that the application's font consumer is broken.

## Export destination and progress

Export captures the selected archive target and destination hierarchy before
starting Git. Final publication refuses a destination or parent replaced during
the operation, preserving the other writer's file. Existing overwrite approval,
temporary archive cleanup, cancellation and progress recovery remain part of
the same workflow. See [Export](EXPORT-PARITY.md) and `ExportDlg.cpp` in the pinned
source.

Native progress fixtures must preserve accepted form ownership rather than
changing model fields behind disabled native controls. Wait diagnostics identify
the actual phase; a generic timeout does not prove a particular shell-wrapper
condition failed.

## Graph gestures and remaining acceptance

A pan test must first obtain an oversized canvas through real graph geometry and
zoom, then press on the settled viewport. Changing the canvas frame after the
press can change legacy scrollbar geometry and correctly invalidate that
gesture. Both scrollbar styles retain exact movement and boundary checks;
`RevisionGraphWnd::OnMouseMove` supplies the successive-pointer-delta contract.

This continuation does not establish every upstream dialog state, physical
Finder integration, signed deployment, Intel execution or minimum-macOS behavior.
The separate ordinary Merge block Save/history failure remains open. Full hosted
success must be established at the corrected source revision; local focused
checks and a successful website deployment do not replace it.

## Grouped checkpoint

The [November 8 checkpoint](qa/history-browser-recovery-2026-11-08.json) passes
17 archive-family Core methods, one Debug app build and 28 native case/engine
pairs cumulatively. The native matrix is fourteen related cases with system and
bundled Git. It retains the initial fixture compile, menu, root-spelling and
ownership/geometry failures and their focused repairs. Previously passing Core,
app build and native groups were retained; no application-source change was
required after the first build. Generated localization resources were checked.

Full Graph checks also require actual Filter/picker retirement and parent command
admission before reopening; physical sheet disappearance alone is insufficient.
Private preferences/repositories, invisible windows, cached app linkage and
logged owned-process cleanup bound this checkpoint. Installed52 and the signed53
package retain their separate source and acceptance records.
