# Repository Browser history and native menu entry

This connected family follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`, especially
`RepositoryBrowser.cpp::ShowContextMenu`, list/tree context entry and the
View Log/Blame dispatch. It extends the existing historical delivery workflows;
it does not replace the Browser's Save/Open recovery, Git operations or command
masks.

## Native folder and contents menus

Both native panes now expose Shift-F10 and accessibility Show Menu through the
same delegates and captured actions as their pointer menus. The contents list
retains its exact entry selection mark independently of highlighted membership.
Pointer selection inside a highlighted group and ordinary keyboard navigation
update that mark; header sorting moves its row without replacing its identity.
Keyboard menus preserve highlights and scroll the selected mark into view.
An empty contents list can expose the existing directory archive action through
its background menu. The folder outline anchors on its selected native node and
retains its existing right-click selection-without-navigation behavior.

Keyboard admission belongs to the actual focused owner window. Accessibility
entry uses the available selected native pane in a visible window; an ordered-out
Browser refuses both entry routes. Modal sheets, file delivery,
mutations, revision picking, Quit, replacement and retirement retain the existing
model restrictions. Menu contents retain generation/revision/directory/entry
receipts, source icons and one-use actions. Replacing the menu retires older
receipts. After native menu tracking closes, unclaimed callbacks retire on the
next main-loop turn, allowing AppKit's selected-item dispatch to finish first.
No menu reconstructs an entry or revision from its displayed title.

Pinned source sets Open as its default action. Native single-entry/folder menus
now give Open the native bold default-item presentation while retaining the
existing Return/double-click routes. File, folder and column menu captions use
localized fixed labels; comparison-mark labels format the localized caption
around the literal user-derived label. Git paths, hashes and user names are not
translation keys. Native menu and focus hooks retire with their view, while
already accepted historical drag transfers retain their existing independent
receiver ownership.

## Historical handoff

Pinned `RepositoryBrowser.cpp` appends both `/endrev` and `/rev` for View Log,
including the selected gitlink object for child-repository history. Native
Browser file/folder history and Blame now publish the current snapshot's
accepted backend before invoking the connected application callback. A previous
working comparison cannot leave that callback using an older backend.
The application handoff is coordinated with the Log/Blame family: the browsed
revision is both the history endpoint and selected revision, and originating
preferences, repository and access are retained.

Tree objects still explain that commit/tag history is required. Bare-repository
Blame, unrepresentable working-path mutations and missing submodule checkouts
retain their existing gates. This family adds no Git command to an excluded
selection or substitutes a current branch tip for the browsed immutable object.

## Evidence and remaining acceptance

The Debug app build and the new Browser context receiver passed with system
and bundled Git on November 22. The [connected record](qa/history-file-context-family-2026-11-22.json)
retains these passes, later retained file-delivery passes and the separate
Log/Blame failures and focused repairs. No capture, physical
gesture or signed acceptance is claimed here.
The authored `BrowserHistoryContextVerification.verify(base:git:)` receiver
exercises actual folder/list pointer, Shift-F10 and accessibility menu entry,
focus retained across sorting, default Open, caption/fallback formatting, source
icons, literal names, popup replacement/close, foreign key owners, busy/ordered-out
and retired owners. Its connected Root workflow covers old-revision file/folder
and initialized submodule Logs, selected endpoints and scoped history paths,
exactly one cold history read, actual idle-cache reopening from Basic/Local
reference scopes and old start tips back to the pinned file endpoint, a real
held-note busy Log left unchanged by repeat opening, and Blame with originating backend/preferences/lease and private recent
files. It asserts unchanged main/child HEAD/index. A secondary direct role check rejects
reuse of a selectable Log; this does not claim an actual CLI output-file launch. Those Browser assertions passed in both Git configurations; physical menu
tracking/localized distribution remain separate. Existing Browser delivery, drag and presentation
checks retain their own scope.

The new grouped driver `scripts/test-history-file-context-family.py` prepares
11 connected modes for system and bundled Git. The hosted history lane selects
the three new context modes together and retains their small JSON/log diagnostics;
existing retained CI entry points remain present. Retained fixtures are copied with `@main` stripped and original
`#sourceLocation` references. Only two private naming transformations are added:
the placement fixture's duplicate `turtleGitBlameToolbarOrder` selector becomes
`turtleGitBlameToolbarPlacementOrder`, and the selection fixture's authored
`held-history` wrapper/markers become `held-helper` so the established exact
shell-argv ownership fallback remains unchanged. Assertions are retained. The
placement case stays invisible at alpha zero while preserving its real screen
geometry; other owned windows are also moved offscreen. Each case has a private
process, HOME, preferences, configuration, pasteboards and temporary resources.
The driver waits for owned windows/sheets, history/file/toolbar requests and
changed-column questions before its completion marker. These are planned checks,
not execution results.

Physical VoiceOver/menu tracking, external applications, complete light/dark
layout states, signed Finder grants, large repositories and every supported
platform remain separate acceptance. This document does not certify all Browser
controls, the whole application or App Store readiness.
