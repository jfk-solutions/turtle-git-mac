# Blame toolbar placement and quick customization

Pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseGitBlame/MainFrm.cpp:120–124`, enables toolbar docking on all sides
and docks the standard toolbar. Line128 selects smart docking; lines146–149
enable the toolbar/pane menu and quick Alt-drag customization. The
[Microsoft toolbar reference](https://learn.microsoft.com/en-us/cpp/mfc/reference/cmfctoolbar-class?view=msvc-170#enabledocking)
explains that EnableDocking also enables floating. User-defined bars are enabled
at line110 and delegated to the framework at lines287–299. Their precise initial
framework placement is distinct from the directly visible standard-toolbar calls.
The source's automatic pane hiding does not by itself prove toolbar auto-hide.

The native family adds placement to the existing standard and named toolbar
composition workflow. It uses native document layout and owned utility panels
for top, bottom, left, right and floating placements. macOS keeps its application
menu in the system menu bar. The AppKit customization palette remains the
standard toolbar's composition editor.

The placement workflow includes drag handles, floating/docking, context and
menu access, saved frames, hidden/restored bars, and quick command rearrangement.
An interrupted drag must leave the saved layout unchanged. Double-click returns to the last chosen dock position and retains the previous
floating frame. Option-drag moves commands within or between visible bars of
the same document. Outside drops are rejected; removal remains available in
toolbar management. A command drag
identifies its source occurrence and owner rather than trusting a title or
arbitrary pasteboard command. Invalid, stale and cross-document receipts do not
change another viewer's layout.

Floating bars retain their document's commands, checked states, appearance and
busy/sheet gates. Closing a bar hides it; deleting it is an explicit toolbar
management operation. Replacing or closing the source document retires the old
floating panels and callbacks. Saved geometry is bounded and fitted to current
screens. Old toolbar settings without placement fields migrate to top docking.

## Checkpoint and boundaries

[The dated checkpoint](qa/blame-toolbar-placement-2026-10-26.json) records the
actual implementation and grouped validation scope, including any failures and
repairs. It does not certify all MFC gestures or complete Blame parity. Physical
pointer/keyboard/VoiceOver, multiple-display behavior, supported macOS/Intel and
signed execution remain separate acceptance work. The installed build12 predates
this family. App Store distribution remains deferred until the owner has tested
the finished local app.
