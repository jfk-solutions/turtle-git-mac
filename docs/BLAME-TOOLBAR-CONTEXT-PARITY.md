# Blame toolbar context menus and managed editor ownership

This continuation uses pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`. The source
`src/TortoiseGitBlame/MainFrm.cpp:92–149` creates the standard toolbar with a
native grip, enables four-edge docking and smart docking/auto-hide, and enables
the toolbar/docking-window menu through `EnablePaneMenu`. User-defined bars and
quick customization retain their earlier native implementation; see
[toolbar placement](BLAME-TOOLBAR-PLACEMENT-PARITY.md).

## Native contextual entry and visibility

The existing toolbar context commands now share pointer, focused Shift-F10 and
accessibility **Show Menu** entry. Standard titlebar grips, named dock/floating
strips, their grips and actual command buttons use the same controller-owned
menu and current visible host anchor. Keyboard entry requires the exact event,
first responder and current owned key window. Accessibility can address a visible
background host, while hidden, foreign, reparented, blocked and retired hosts are
refused. Primary toolbar-button press and drag/double-click placement semantics
remain separate from menu entry.

The context adds a checked **Toolbars and Panes** submenu for the Standard bar,
user-named bars, Log and Properties. Hidden other bars can be restored from an
available toolbar's menu. The main View menu remains the route when every bar
is hidden. Custom names remain literal user text. Existing settings, placement,
reset, hide and pane/source icons obey the injected context-icon preference.
This is an intentional Mac adaptation of the framework-provided popup, using
existing TortoiseGit artwork by role. It does not claim that MFC's generated
customization items have a one-to-one project resource-icon mapping. The earlier
retained fixture's no-context-artwork assumption is superseded by the requested
all-context-icons behavior; unrelated text-only main-menu icon assertions remain.

Each actionable item is single-use. Its receipt captures the originating model,
document epoch, menu and configuration generations, pane layout/visibility and
weak native host/window identities. A changed menu, external configuration,
replacement document, layout change or detached host cannot redirect a retained
action. Entering toolbar management or the native customization palette revokes
older context receipts before a sheet becomes attached.

## Managed editor return and closure

Manage Toolbars keeps its captured native parent and editor through both sheet
links being cleared. Done, Escape, native close-delegate requests and explicit
close share that drainage path. Configuration writes stop as soon as closing begins;
an old session cannot modify a subsequently opened editor. `activeEditors` retains
a dedicated Quit lease until the accepted editor's exactly-once completion.
Owner commands and normal document closure remain blocked while the editor is
pending. Forced document closure retires the editor and defers the owner's
completion until that same editor has drained. Existing File Open, Find, Go To,
column questions and their independent counters keep their own contracts.

## Checkpoint and remaining scope

The parent batch's Debug app build passed. Its first Blame context receiver
failed while locating the actual Done control using an NSButton-only lookup.
Invisible SwiftUI hosts also omitted button proxies from the public accessibility
tree; actual Done's default Return key equivalent subsequently worked. A later
fixture assertion incorrectly assumed `performClose` starts closure on an
attached sheet. The repaired fixture checks the native close-delegate request
and labels that narrower boundary explicitly; no titlebar click is claimed.
These failed attempts remain in the parent batch's receiver logs.
The [connected checkpoint](qa/history-file-context-family-2026-11-22.json)
now records passing Blame context, retained customization and placement cases with
both Git engines. It mounts real native hosts, uses private popup responses and
actual sheets, checks stale command refusal and Done/Escape/native close
requests/forced retirement, and preserves repository contents. Editor detachment,
dedicated lease release and global Quit guards pass. No signed acceptance is
claimed.

Actual physical sheet close-button availability and clicks, pointer/keyboard/VoiceOver gestures, AppKit customization-palette
interaction, all floating/overflow/multiple-display combinations, localized
bundled-app presentation and signed Finder/platform acceptance remain open.
This continuation does not certify all toolbar or pane behavior, the entire
Blame dialog, complete TortoiseGit parity or App Store readiness. Frozen signed54
is a separate source snapshot and excludes this implementation.
