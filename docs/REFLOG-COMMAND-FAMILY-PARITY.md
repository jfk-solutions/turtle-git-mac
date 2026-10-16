# RefLog native commands and column reset

Source pin: `7338078f8ddd924b8cddee35f512f2286072136d`,
`RefLogDlg::PreTranslateMessage/OnFind`, `CRefLogList::InsertRefLogColumn` and
`ColumnManager::OnContextMenuHeader/AddMenuItem/ResetColumns`.

RefLog now scopes F3, F5, Ctrl-F and native Cmd-F to its active owning event
window. F3 opens/reuses the modeless Find dialog, matching the source rather than
silently finding next. Modified function keys and events from another window do
not run commands. Editable fields keep their text shortcuts. Escape follows the
ordinary owned Close/selection-cancel path. Child sheets, retained unified viewer
work, mutation and retired owners retain their existing command guards. F5 may
supersede an owned read; Find stays unavailable while the list loads.
Find inherits the owner's appearance.

Ctrl/Cmd-A and Ctrl/Cmd-C route only from the focused native report table. Return
and keypad Enter use its existing OK/chooser behavior. Shift-F10 scrolls the
selected event into view and anchors the native row popup beside it; native
accessibility Show Menu uses the same route. Pointer menus retain their actual
click target and selection semantics. No global event monitor is added.

Each row or header popup owns one session. Executing any leaf consumes that
session; constructing another popup, refreshing the model or retiring its table
invalidates retained targets. Disabled actions refuse direct dispatch too. Row
menus still validate the complete captured events/reference and original icon
preference. Unified-diff Shift choices are captured when the popup is constructed,
so later modifier changes cannot redirect the selected tool.

The header follows source order: Reset column order, then Ref/Action/Message/Date.
Logical column zero, Hash, is mandatory and is omitted from hiding, including
when restoring old saved hidden-column settings. Reset asks source Yes/No with
Yes default and restores native default order, widths and visibility. The current
selection and vertical reading position survive. No leaves the private layout
unchanged. Reset owns its question, repository grant and Quit counter until reply;
forced closure dismisses the sheet and refuses late reset or persistence. A
changed layout or model generation invalidates a captured reset.

[Grouped evidence](qa/reflog-command-family-2026-10-16.json) records twelve
passing case/engine combinations: commands, table, Find, operations, advanced
actions and lifecycle, each on system and packaged Git. One Debug build passed
with two exit-zero/no-output compiler diagnostics. Fixture repairs and failed
attempts are recorded; no application rebuild or Core suite was repeated for
those fixture changes. All sixteen owned receivers were reaped and independently
absent. The actual owned Reset sheet was closed forcibly, and application Quit
refused while its question retained work. Injected Yes/No replies verify accepted
layout defaults and unchanged refusal, including selection and scroll position.
The built help remains byte-identical to source and the website renders 262
documents with no unresolved fragments.

This is a native adaptation, not complete RefLog,
physical keyboard/popup/VoiceOver, minimum-macOS or signed Finder/App Store
certification.
