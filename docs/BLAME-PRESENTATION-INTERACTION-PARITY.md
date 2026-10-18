# Blame zoom and revision tooltips

Pinned TortoiseGit source: `7338078f8ddd924b8cddee35f512f2286072136d`.
The source references are `TortoiseGitBlameView.cpp::OnSciZoom`,
`CreateNewFont`, `GetBlameWidth`, `OnMouseHover` and Scintilla's
`Editor.cxx::ZoomIn` / `ZoomOut` and `KeyMap.cxx` zoom shortcuts.
This extends the [existing Blame viewer](BLAME-PARITY.md), including its shared
TextKit source, attribution table, locator and wrapped logical rows.

## Connected native behavior

The View menus provide Zoom In, Zoom Out and Actual Size with the existing
upstream zoom artwork. Command-Plus (also Command-Equals), Command-Minus and
Command-0 route through the captured native owner. The original control-wheel
gesture and a macOS command-wheel adaptation work over source and attribution;
trackpad magnification provides the same transient operation. Precise wheel and
pinch deltas accumulate into bounded steps. Unmodified scrolling keeps its
ordinary behavior. A modified gesture at a limit is consumed without scrolling
the source accidentally.

Zoom is per document and does not rewrite the configured font. Its offset has
the pinned Scintilla range -10 through +60. The realized size is the configured
1...1000 point size plus that offset, with a one-point minimum. Actual Size
restores the current configured font. Settings changes retain the transient
offset; a replacement File/Open document starts at its own default offset.
Initial font settings are read from the owning preferences, rather than global
defaults. No repository, index or file bytes are changed by zooming.

Source text, syntax-family fonts, attribution labels, line heights and column
widths use the same effective size. Line-number widths account for the number of
digits. Source and attribution retain matching row rectangles, including wrapped
lines. Reflow retains the top logical source row, the pixel offset within it,
horizontal origin when unwrapped, and the UTF-16 selection. A smaller row clamps
an offset that no longer fits; a document edge may constrain the viewport.

Busy/reloading, navigation-sheet, Open, child-operation, deferred Quit and retired
owners refuse changes. Menus resolve the live focused owner; background or stale
windows cannot redirect a key or wheel gesture to another document.

## Revision metadata and bounds

Both attribution cells and source-point tooltips resolve the hovered logical
row. They show its full revision, author and email, the configured date format,
subject and a bounded message body. Origin filenames appear for complete/follow
history, cross-file detection or differing attributed paths. Selection is not
used as the tooltip identity. The source uses one native tooltip region with a
binary logical-row lookup, without adding attributes to every character.

Loaded history supplies full messages. A complete path-filtered Log can omit a
copied line's originating revision; loading fetches only those missing hashes
through the existing cancellable, mailmap-aware batches of up to 128. These
tooltip-only entries do not change visible Log rows or age ranks. Hover itself
does not run Git. Replacement, failed load and retirement revoke stale metadata;
a late mismatched entry cannot supply another line's author or message.

The body retains the source's nominal fifteen-line / seventy-UTF-16-unit wrapping
heuristic, including its handling of a final line without LF. The complete native
tooltip is limited to 8000 UTF-16 units including an ellipsis, and truncation
preserves whole grapheme clusters. This is a deliberate macOS adaptation of the
source's raw CString truncation. Working-tree fallback avoids invented epoch
dates and unrelated commit metadata.

## Validation and remaining acceptance

The Debug app, 38 distinct focused Core cases and six native case/engine pairs
passed. [Dated evidence](qa/blame-presentation-interaction-2026-10-18.json) records
the actual initial compile failures, fixture teardown crash and focused repairs.
Every executed receiver was reaped and independently confirmed absent. The native
input evidence uses synthesized discrete wheel/key events; precise deltas and
pinch are implemented but physical gesture acceptance remains open.

The native group covers actual fonts, line geometry, wrapped and horizontal
viewport/selection preservation, owner routing, limits and saved preferences,
per-row tooltips and stale Reload behavior. The existing wrapping and source
editor receivers retain directly affected regression assertions.

Physical trackpad/wheel direction and smoothness across devices, tooltip timing,
VoiceOver reading, every original font/DPI combination and current signed sandbox
delivery remain separate acceptance. A focused local pass cannot establish full
Blame visual parity, a full hosted CI pass or App Store readiness.
