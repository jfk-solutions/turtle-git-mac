# Native RefLog report list

Pinned `CRefLogList::InsertRefLogColumn` defines Hash, Ref, Action, Message and Date
in that order, with persistent column-manager settings under `reflogloglist`
(version 6). RefLog uses reflog selectors for list positions; two rows can have
the same commit hash and still represent different history events.

The native `ReferenceLogNativeTable` replaces the SwiftUI Table with an AppKit
report list. It retains all five source columns, monospaced hashes, native
light/dark text/selection/background colors and full-value tooltips. Column width,
order and visibility are saved in the controller's supplied preference store.
The header supplies checkable column entries; at least one column remains visible.
Unknown columns, duplicate stored ordering and malformed/nonfinite/out-of-range
widths are ignored. This uses native points and a fixed five-column schema rather
than copying Windows registry/DPI storage. Row sorting remains absent: reflog
position order controls selectors and deletion semantics.

Selection binds by selector, preserving repeated hashes as independent rows.
Right-clicking an unselected row selects it; right-clicking a selected member
retains the multiple selection. Double-click uses the existing revision/picker
activation route. Return accepts the dialog, as its default OK button does.
Find's model-selected row is revealed by the native scroll view. Copy and Select
All have native responder actions with the same owner/busy gates.

All previously implemented RefLog context actions are retained as native menu
items: comparisons and merge-parent unified choices, Show Log, Browse Repository,
Reset/Switch/Checkout, branch/tag/export, guarded Delete and Stash Apply, two-row
comparisons and three Log range variants, and the three clipboard formats. Original
command icons and the app context-icon setting are retained. Merge parent metadata
is requested for rendered rows and cached by the existing model.

Each menu item retains a command target with a weak coordinator reference. Its
unique Objective-C action selector avoids NSObject's inherited `perform` overloads.
Dispatch checks live window/model state, busy and sheet gates, reference identity
and the complete selected reflog records. A retained menu cannot silently redirect
an old `HEAD@{0}` action after that position is replaced by a different event.
The existing Core delete snapshot check remains responsible for external changes
which have not yet been loaded by the window.

Clipboard date formatting now uses the same supplied preferences as the displayed
list. Clipboard payloads retain the already implemented source CRLF format. Private
pasteboards are supplied by native QA; ordinary app commands use the system board.

The focused native fixture checks actual table/menu action dispatch, repeated-hash
selection, all three two-row range entries, original icons and icons-off, displayed
and copied date settings, Find scrolling, saved width/reorder/hide restoration,
busy/changed-selector/closed action refusal and unchanged repository state during
UI interactions. A later explicit fixture commit verifies stale-selector rejection;
it is not an app mutation. All test windows and receivers are owned and closed.

This remains partial RefLog parity. Other upstream revision commands, exact
Windows menu conditions/order, physical row/column gestures,
VoiceOver, selecting/bare/stash variants of the new list, and signed sandbox/Finder
execution still need implementation or acceptance. The gallery image predates this
native list replacement; no new displayed screenshot is claimed by object checks.

The final Debug build, two native receiver runs with system/bundled Git, and
two site documentation checks passed. Two earlier receiver runs passed after
repairing the action selector; the final group added visible-header, double-action
and displayed-date checks. The initial dispatch failure was sampled, then only
its verified owned PID was terminated and reaped. No full Core suite, physical
gestures or signed distribution is certified. [QA evidence](qa/reflog-table-2026-10-13.json).

The transport batch also connects RefLog to the optional shared `LogFontForLogCtrl`,
`LogFontName` and `LogFontSize` settings in its supplied preference store. This
macOS consistency behavior retains default system text/monospaced hashes when
turned off and applies the configured font to all five columns when on. Row height
grows with font metrics and returns to 22 points when disabled. Native QA checks
large-font cell assignment and row height; physical appearance, live Settings
interaction and all-script rendering remain open. Transport menu ordering and
its validation scope are recorded in [operation handoffs](REFLOG-OPERATIONS-PARITY.md).

## Connected command/header family — October 16, 2026

The [native command family](REFLOG-COMMAND-FAMILY-PARITY.md) now adds source-style
owned Reset, mandatory Hash, keyboard/AX row menus, captured modifiers and
single-use popup sessions. These supersede the earlier at-least-one-visible
header rule and reusable action-target behavior. Layout still uses native points
and private preferences; physical and signed acceptance remain open.
