# Shared message-editor line commands and zoom

This family adapts the inherited Scintilla commands in TortoiseGit's shared
`CSciEdit` message control to native editors. The reference is pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`, specifically
`ext/scintilla/src/KeyMap.cxx:159–174`, `src/Utils/MiscUI/SciEdit.cpp:323–326`,
`938–952`, `1050–1067` and context-menu anchor restoration `1073–1269`, and the Commit/Merge/Rebase/Input consumers (`IDD_COMMITDLG`, `IDD_MERGE`,
`IDD_REBASE` and `IDD_INPUTDLG`).

## Connected workflow

The shared native editor supplies whole-line Copy/Cut/Delete, selected-text or
current-line Duplicate, and line Transpose. These commands use the existing
source-derived `PatchLineEditing` planner over the message's plain text. This
message workflow operates on decoded editable Unicode; the separate Unified Diff
byte-buffer contract is not an encoding promise for repository commit messages.
Existing commit-message encoding validation still runs at its own save boundary.

The native shortcuts use Command–Option C/X/K/D/T to avoid replacing Cocoa's
ordinary Copy/Cut and character-editing shortcuts. A focused Edit-menu **Message
Lines** group and matching icon-bearing text menus expose the same actions.
Source line-boundary, selected-line inclusion, final-line and caret behavior
remain in the shared planner. A text transaction includes the existing configured
hard wrapping in one Undo step, with exact before/after selection snapshots.
Context-menu inspection preserves the original caret/selection as SciEdit does;
Cocoa's clicked-word selection cannot silently change the line command target.
Ordinary typing, completion, spelling, issue links and source-style parsing
continue through their existing message-control paths. Tab retains dialog focus
traversal instead of introducing a tab-indentation command into messages.

Temporary Zoom In/Out/Actual Size adjusts the current editor's configured base
font without writing preferences, altering text or adding an Undo action.
Effective font resolution is shared by Commit's synchronous style application
and asynchronous Merge/Rebase/Input parsing. Resetting or replacing the message
session retires retained menu/Undo ownership and restores its configured size.

Commands resolve the focused live editor and refuse busy, read-only, composed
IME, sheet/modal, closed or retired owners. Rebase additionally carries its
captured form context. A metadata, busy or selection refresh invalidates retained
menu actions while preserving the current document's text Undo and zoom. A new
replay message document resets both even when its text is identical. Native
retained menu receipts refuse stale contexts and document sessions.

## Verification and remaining work

The [dated checkpoint](qa/message-editor-commands-family-2026-10-27.json) records
the actual grouped Core/native/build scope and any failed attempts. Local native
receivers are isolated from user repositories, preferences and pasteboards and
close their owned windows/processes. This family does not certify the entire
SciEdit keyboard map, arbitrary rectangle editing in message controls, every
platform IME/keyboard layout, physical VoiceOver, full dialog geometry, signed
external grants, Intel/minimum macOS execution or complete hosted integration.
The [signed build15 acceptance](qa/signed-consolidation-build15-2026-10-27.json)
packages this implementation. Actual installed Commit accepted Duplicate through
both the main menu and physical shortcut, and temporary zoom/reset worked. It
also exposed a gap that the earlier receiver did not cover: standard Undo was
disabled and its keyboard action did not reach Commit's private UndoManager.
The receiver had invoked that manager directly. Build15 therefore does not pass
the complete editor acceptance gate; the native responder repair now passes its grouped checks. Installed acceptance
of that repaired source remains required before the next preview is accepted.

The [responder follow-up](qa/message-editor-history-responder-2026-10-27.json)
routes standard `undo:` and `redo:` selectors to the focused editor's manager,
matching the existing native Compare editor's responder pattern. Main-menu
validation and physical message shortcuts use that same guarded route. Context
history entries carry the captured document/window identity and source icons;
an old menu cannot undo a replacement draft. Busy, composition, sheets and
retirement disable history without discarding it. Metadata-only refreshes retain
the current document's history. The follow-up receipt distinguishes this repair's
checks from the earlier direct-manager evidence and installed build15 failure.

[Installed build16](qa/signed-consolidation-build16-2026-10-27.json) passes the
bounded Commit follow-up: standard main-menu Undo/Redo and physical shortcuts
restore the expected draft states on the current keyboard layout. The context
menu exposes its named Undo action. Other adapters, layouts, IME and VoiceOver
retain the limits of the grouped native and physical evidence above.
