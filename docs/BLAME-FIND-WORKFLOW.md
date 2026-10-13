# Native Blame Find workflow

The pinned viewer's `OnEditFind`, `OnFindDialogMessage` and `DoSearch` define a
modeless, reused Find panel. Selection prefills its draft; Find Next commits text
and Match case. Matching searches author/source fields independently and selects
the whole matched source line, including its line break. Substring-only selection
would differ from this source behavior.

TurtleGit now keeps selected-text prefill separate from the last applied query.
Cancel discards that panel's edits. Repeated Find focuses/reuses the existing panel
without replacing its draft. Closing it removes the child relationship; reopening
gets a fresh selection-prefilled draft. Query and Match case use the owner's
supplied defaults store, so private verification does not write user preferences.

A wrapped match briefly pulses the native panel border twice, adapting the source
Find-window flash. No match presents an informational native sheet with the query,
leaves the selected line intact and blocks further search/ordinary owner close
until OK. The viewer still shows line/wrap status. The modeless panel allows parent
navigation while no alert is active. Owner retirement disposes the panel, any
information sheet and queued pulse callbacks, and fences later model search writes.

The native fixture covers actual panels, field focus, whole-line source selection,
wrap pulse, actual NSAlert controls, ordinary close refusal, parent retirement,
private preference isolation and unchanged HEAD/index/source bytes. Existing source
and wrap fixtures remain part of grouped verification. Complete Edit menus,
accelerator/VoiceOver behavior, all platforms/encodings and signed acceptance remain
open; this is not a certification of the entire Blame dialog.

The Debug build and six grouped native Find/source/wrap cases passed with system
and packaged Git. All owned receivers were independently checked absent after
reaping. Core and AppStore checks were not repeated: this batch changes the native
workflow without changing Core logic, resources, targets or entitlements. The
website build passed. [Batch record](qa/blame-find-workflow-2026-10-13.json) records
scope, source hashes and the still-unverified full hosted result.
