# Merge Encoding and Go To dialogs

Baseline: pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`EncodingDlg.cpp/.h`, `BaseView.cpp::AskUserForNewLineEndingsAndTextType`,
`ReplaceLineEndings`, `OnEditGotoline`, `GotoLineDlg.cpp` and both dialog resources.

Both text viewers now offer **Encoding…** beside writable-pane format controls.
The native owned sheet shows the pane name, Encoding and EOL dropdowns, followed
by OK/Cancel. Nine encodings follow the source order: ASCII (adapted to explicit
Windows-1252), UTF-16 LE/BE without/with BOM, UTF-32 LE/BE, UTF-8 without/with BOM.
EOL choices are Auto plus CRLF, LF, CR, LFCR, VT, FF, NEL, LS and PS.

Auto leaves every original ending intact, including mixed endings and a missing
final terminator. Explicit EOL converts only existing endings. Encoding validation
runs against the complete converted text before either property changes; lossy
conversions are rejected. OK changes the editor draft, never the disk or index.
Cancel preserves both settings. Replies from retired/reloaded/changed contexts
are discarded; duplicate prompts are fenced. Existing Undo covers text/EOL edits;
encoding metadata is not grouped into that Undo step, matching the source's
remaining format-Undo limitation. Legacy input-codepage detection remains partial.

The Go To prompt's title and OK/Cancel now match its source resource. Existing
source-coordinate navigation excludes gaps and synthetic final rows. Source
`OnEditGotoline` explicitly refuses a one-line pane, so that exclusion remains.
Bounds/digits are validated before accepting the native prompt.

Validation outcomes are recorded in the dated QA report. Physical menus/keys,
light/dark/minimum-size captures, VoiceOver, full codepage compatibility and
signed sandbox acceptance remain open. Native choice callbacks are injected for
model acceptance tests; those tests do not prove physical interaction with every
popup item.

Three focused backend tests and the grouped native receiver passed. The latter
exercised two-pane acceptance/Cancel/stale-close and three-pane acceptance, plus
actual attached-sheet Close/Quit guards. See the
[dated QA record](qa/merge-format-2026-10-12.json) for the compiler-fixture repair
and exact scope. No new captures were published.

## Source Encoding sheet and independent drain — October 17, 2026

Encoding now uses a native source-shaped sheet instead of a generic alert. Pane
name, permanent Encoding/EOL labels, source-ordered nine/ten native popups and
lower-right OK/Cancel retain the resource hierarchy. The pane prefixes the window
title. Invalid programmatic selection leaves the sheet open with native inline
validation; normal popups retain the selected initial values.

Acceptance, Cancel/Escape, external sheet completion and owner closure settle
once and disable the old controls. Native prompt lifetime is tracked independently
for Quit. Compare now retains its actual prompt and cancels it on model retirement,
including when an editor window is retained for replacement. Both model routes
refuse retired/pre-start/window-changed contexts before presenting a chooser.

Three-pane retirement now retires delivery immediately but keeps operation
accounting until an injected/native chooser actually drains. The prior immediate
counter release for a held injected continuation was not worker completion. Native
cancellation settles the prompt; a genuinely suspended injected choice still guards
Quit until its late reply is discarded. Existing format snapshots, source-state
projection, Auto/EOL conversion, encoding validation and Save/Undo semantics remain.

All seven static resource controls have partial mappings. The Debug build and all three grouped native families passed on their first attempt: source prompt/retirement, retained two-pane format transactions and three-pane formatting/Undo/Save. Both raw light/dark captures were individually reviewed; pane, labels, choices and lower-right buttons fit. All three owned receivers were reaped and independently absent. Core was unchanged and not repeated. See [batch evidence](qa/merge-format-source-family-2026-10-17.json) for build diagnostics, capture provenance and acceptance limits.

Source ASCII remains the explicit Windows1252 adaptation; physical popups/keys/VoiceOver, full legacy codepages and format/Save
boundaries, signed sandbox and complete upstream parity remain open.
