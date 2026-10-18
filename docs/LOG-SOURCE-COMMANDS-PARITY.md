# Log keyboard, focus and message commands

Implementation batch against pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This is a partial Log-family source audit; it does not certify every Log control or the full port.

## Source mapping

| Source | Native behavior |
| --- | --- |
| `src/Resources/TortoiseProcENG.rc`, `IDR_ACC_LOGDLG` | F3 / Ctrl-F Find; F5 / Ctrl-F5 / Shift-F5 Refresh; Ctrl-L / Alt-D focus revision filter; Ctrl-E select revision-filter text; Ctrl-C / Ctrl-Insert Copy; Escape clear filter or close. Cmd-F / Cmd-R / Cmd-L / Cmd-C provide macOS aliases. |
| `src/TortoiseProc/LogDlg.cpp`, `OnFocusFilter`, `OnSelectSearchField` | Both focus the **revision** search field, retaining focus-only versus select-all semantics. The changed-path filter remains separate. |
| `OnBnClickedRefresh`, `Refresh(true)`, `OnRefresh` | Explicit Refresh clears revision search and its validation error. Background `reload()` retains revision search. Refresh retains the path filter and other history options. |
| `OnExitClearFilter` | Escape outside editable text clears revision search and focuses its field; Escape with no active search closes. Search-field Escape keeps its native field delegate, clearing that field without closing the window. |
| `OnOK`, `GitLogListBase.cpp` Return behavior | Return owned by the revision list is consumed even when its optional comparison is disabled; it cannot activate the default Close button. |
| `OnContextMenu`, message pane | Copy selection, Copy all and Edit Notes use source icons and groups. Copy all preserves selection and scroll position. Notes uses the existing note read/editor/save/refresh flow, refusing a second open while a draft is owned. Existing link actions and native Select All remain available. |
| `OnEditCopy`, `CopyChangedSelectionToClipBoard` | Window-owned Copy dispatches revision details, selected changed paths, or selected message text according to the focused native pane. The injected model pasteboard owns all message copies. |

The source Control/Option shortcuts apply outside editable responders. Native editable text keeps Control-F/E/L, Option-D, marked input and its own Copy/Escape behavior; Cmd-L is the explicit revision-filter focus alias while editing. No global key event monitor is installed. Commands require the event's own key Log window and respect active operations, child dialogs and application Quit confirmation.

A message popup captures its document/style request, revision selection, model load generation and popup generation. A single shared receipt permits only one action from that popup. Replaced, stale, busy, child-owned, quitting and retired callbacks cannot copy, navigate or replace a Notes draft. Copying directly to the model pasteboard avoids reading or writing an unrelated clipboard in private tests.

## Grouped validation

New fixture: `docs/qa/log-source-commands-native-2026-10-18.swift`; runner: `scripts/test-log-source-commands.py`. The fixture uses a private repository, preference suite and pasteboard, closes its windows and waits for owned Log history/note/message operations. It covers source key routes and native aliases, editable ownership, explicit versus background refresh, Escape, Return shielding, revision/message copy, source message menu icons, one-shot/stale/blocked receipts, the actual Notes read flow and draft protection, and unchanged HEAD/index entries/worktree bytes.

The parent Debug build compiles `ApplicationDelegate.swift`'s captured Log `confirmingQuit` true/reset-false loops and asynchronous shutdown drain path. Both engines pass the new receiver and retained `scripts/test-log-message-family.py` navigation/message cases: six case/engine passes. The initial fixture query was nondeterministic with default hash search; private Subject-only search and native selection/coordinator settlement preserve all result assertions. [Batch evidence](qa/parallel-port-families-2026-10-18.json) records the compile access-boundary repair, failed attempt and affected rechecks. This native-only family reuses existing note, clipboard-details and history operations; it adds no new Git/Core operation.

## Remaining scope

This batch does not claim compositor/physical-key parity, VoiceOver acceptance, physical Finder behavior, signed distribution, hosted CI, or complete Log-dialog visual parity. Source accelerators that conflict with macOS editable-text commands intentionally retain native text editing while the field owns focus. Existing Notes mutation validation remains in its original workflow family; this fixture checks the new message-menu entry and protected draft lifetime. Revision-list Blame items are deliberately absent: the source ordinary Log masks those items out; their Blame-hosted consumers require their own audit.
