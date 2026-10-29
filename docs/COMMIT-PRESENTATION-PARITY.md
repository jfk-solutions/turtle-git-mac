# Commit workflows across native presentations

The optional Git Gui-style staging presentation changes how files and their patch
are arranged. It must retain the Commit dialog's destination, message metadata
and operation semantics. Pinned `TortoiseProcENG.rc::IDD_COMMITDLG` (253–264)
contains new-branch, provider/issue and author/date controls; `CommitDlg.cpp::
PrepareStagingSupport` (3100–3133) changes checkbox/patch behavior without removing
those controls. `PreTranslateMessage` (1641–1681) also keeps the commit shortcut
independent of staging mode.

## Shared destination and message form

The native destination/provider/issue section now sits above the presentation
split. Both layouts render the same new-branch field, selected destination,
provider action and conditional issue field. Both use the same captured form
receipt and existing field identifiers. A layout switch preserves the draft,
branch choice, author/date overrides and issue selection instead of leaving
active options without an editable control.

The Classic message band and Git Gui right-hand message group use one metadata
view for Amend, comparison against the last commit, author/date/time/reset and
Signed-off-by. Existing labels, native fields, option transitions and defaults
are reused. The Git Gui Refresh action shares the existing compact layout-picker
band. The destination spinner reserves its space; the staged/unstaged list bands
and their operation/status geometry remain separate and unchanged by this form
extraction. Showing an explicitly enabled metadata control can change the
message area's required space, as in Classic. The embedded patch preview uses
an explicit smaller minimum text viewport while remaining scrollable; standalone
Patch dialogs retain their existing 360-point minimum. The preview's fixed
loading/status bands are preserved so metadata can fit without inheriting the
standalone preview's large minimum height.

Show Whole Project and Message only were already common footer controls; this
change does not claim they were missing. File menus, keyboard routing and
presentation-specific file focus belong to the connected workflow batch and are
reviewed separately from this shared-form change.

The grouped native checkpoint passes with both system and bundled Git, including
the retained Commit-option and Git Gui staging regressions. This implementation note
is not a certificate of every Commit control, visual layout, physical gesture,
signed deployment or whole-port parity.

## Shared file lists and commands

Classic and Git Gui panes now use the same captured file-menu view and existing
status policy: compare/unified diff, conflict resolution, Add modes, revert,
restore-after-commit, LFS/index flags, file transfers, history/open/export/delete,
ignore, clipboard and changelists. Git Gui adds Stage/Unstage as its first action;
its double-click retains that transfer meaning. Captured GUI menus retain the
layout, list generation, ordered entries and staging states. Refresh, another
selection/side, changed state, layout replacement or retired owners reject stale
actions. A menu opened on an inactive pane uses that captured side for unified
diff and statistics rather than reinterpreting the current selection.

The native list bridge now supplies active-list focus, Space transfer, delete,
copy, working-file drag/drop, refresh positions and source column commands in
the two staging lists. Saving their Path/Status order or widths preserves other
Classic report columns. The shared Commit menu retains commit variants,
message commands, form options and categories in both layouts. GUI mode omits
only the forced-staging toggle and separate Classic patch-window commands.
Conflict acknowledgement selects the actual unstaged conflict row and cannot
steal focus after newer input or a layout change.

The embedded patch opts into a smaller scrollable text minimum so the source
metadata controls fit alongside it. Standalone patch windows retain their
existing minimum. Fixed GUI operation/loading/status list bands are preserved.

The [grouped checkpoint](qa/commit-presentation-workflows-2026-10-29.json) records
actual validation and limits. Physical menu/keyboard/pointer delivery, complete
light/dark/locale layout review and installed signed acceptance remain separate.
The independently identified shared working-file Compare/conflict-intent routing
and Repository Browser late-materialization ownership gaps remain open for their
next connected workflow batches; this presentation change does not repair them.
