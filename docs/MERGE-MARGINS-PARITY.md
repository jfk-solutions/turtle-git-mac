# Merge line-change margins

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`BaseView::DrawMargin`, `GetMarginWidth`, `GetWhitespaceBlock`,
`GetWhitespaceString`, `IsBlockWhitespaceOnly` and `FilterWhitespaces`.

The two-pane and three-pane editors now draw the original lineadded,
lineremoved, lineconflicted, lineconflictedignored, lineedited, lineequal and
linewhitespace artwork, alongside the retained moved/marked icons. Each asset
is copied unchanged from the pinned resources with its SHA-256 and source path
in Icons/provenance.json. Colored artwork is retained in both appearances.

Addition/removal aliases share their source icons; unresolved result slots and
ignored conflicts have separate icons. Edited rows retain their edit symbol.
Resolved, resolved-empty and ordinary gaps have no invented status icon.
The two source panes can replace their normal state symbol with Identical block
or Whitespace-only changes. The combined view and result have no peer and retain
their state symbols. Explicit marked blocks take priority over moved blocks;
moved blocks take priority over the whitespace/state symbol. Marked words and
search matches are separate text highlights, not marked blocks.

Whitespace classification uses original record payloads and endings. Normal rows
with equal payloads and pairs of empty payloads have no override, even when their
endings differ. Equal non-normal payloads get Identical block. Removing only
space, tab, CR and LF detects single-line whitespace changes. Otherwise the
source's same-state/Empty block search extends at most eight records each way;
block concatenation is refused above 2048 UTF-16 units including the source's
two-unit-per-row allocation allowance. Empty can inherit an adjacent non-Normal
state. Identical/reflowed blocks update the bounded block's icons together.
Nonbreaking space and canonically equivalent but byte-distinct Unicode are not
silently normalized. This decoration does not change comparison keys, folding,
Find categories, difference counts or saved bytes.

Classification is cached in the native ruler when original records/states or
peers change; drawing uses cached symbols and artwork. Native hover labels describe
the visible symbol; moved tooltips and double-click navigation retain their
captured peer route. Hidden/fold-marker rows do not draw icons or tooltips.
Hiding line numbers retains the source's 20-point icon margin in every pane;
showing them restores its measured number width. Initial indentation/number
defaults and later preference notifications now read the owning window’s supplied
preference store in both editors; they previously mixed it with global defaults.
Existing per-pane EditorConfig toggles remain independent on later Apply.
Existing wrapping and linked
scrolling use the resulting document width.

The source caches icons as screen rows are drawn; the native projection classifies
view records in a deterministic forward pass before drawing. Exact virtual wrapped
padding/icon repetition, physical margin/hover input and
VoiceOver traversal, large-file performance, minimum-OS and signed installed
acceptance remain open. This does not certify complete Merge or app parity.


## Native captures and validation

Unedited, inactive native compositor captures in both appearances. The comparison
shows the icon-only margin and whitespace/added/removed symbols; the conflict
window shows equal source Base records, source additions and unresolved result
slots. Inactive toolbar controls use normal macOS dimming. These captures do not
certify every margin gesture or whole-window upstream geometry.

![Native merge-margin-compare-dark](site/assets/merge-margin-compare-dark.png)

![Native merge-margin-compare-light](site/assets/merge-margin-compare-light.png)

![Native merge-margin-conflict-dark](site/assets/merge-margin-conflict-dark.png)

![Native merge-margin-conflict-light](site/assets/merge-margin-conflict-light.png)

[Grouped evidence](qa/merge-margin-2026-10-16.json) records the 11 passing
Core checks, four native family cases, the capture follow-up, the initial
preference failure and two fixture corrections. All test-owned receivers and
capture helpers were reaped. Complete physical, signed and hosted acceptance
remain open.


## Margin selection and capture — October 16, 2026

The gutter now handles native single-click, Shift-click and drag in the two-file,
combined and three-way editors. A normal click focuses the owning pane and selects
the entire logical line without its final ending. All participating panes retain
matching row boundaries separately from the active text selection. Copy and Cut
use explicit selected text; block choices retain the complete selected row range.
Removed records and blank conflict slots keep their view coordinates rather than
selecting serialized marker text. The two/three-pane mapping follows the same
authoritative alignment used by existing navigation. Unmapped serialized-result
fallbacks do not invent peer coordinates.

Shift and drag keep a fixed caret origin. As in BaseView::AdjustSelection, the
endpoint in a margin is the beginning of the clicked screen fragment: the endpoint
row remains in the block selection even when its text is not selected. Reversing
direction preserves that origin. Clicking a wrapped fragment selects its whole
logical line, while later extension retains the clicked fragment's origin. Native
selection affinity supplies the direction when extending a pre-existing text
selection. Source line endings and Unicode payloads are retained by the existing
clipboard/editing paths; selection does not modify files or create Undo entries.

Double-click preserves moved-block navigation and expands a folded marker through
the existing shared folding controller. An owned drag can autoscroll using AppKit
while the pointer is outside its editor viewport. Mouse Up cancels its timer;
owner closure explicitly retires every ruler. No global event monitor, pointer
posting or other application's input is used. Timer callbacks hold only a weak
owner and revalidate their captured gesture before applying.

Captured text, model/input revisions, folding revisions, viewport size and font
validate later drag events. Editing, Undo/reload, changed folding/geometry, an
owned sheet, busy or retired models reject stale gestures. Another native user
input revokes the retained origin through the editor's existing input revision.
The shared boundary renderer now supports a nonempty native text selection as
well as its previous caret-only navigation blocks. Existing Copy/block navigation
semantics remain available.

Sources: BaseView::OnLButtonDown/OnMouseMove/OnLButtonUp/OnTimer,
OnLButtonDblClk, AdjustSelection and SetupAllViewSelection. Native autoscroll
and TextKit fragment hit testing adapt Windows capture/screen coordinates. Exact
Windows virtual padding/column positioning, non-move double-click word semantics,
physical trackpad/drag/VoiceOver and signed/minimum-OS acceptance remain open.


[Grouped selection evidence](qa/merge-margin-selection-2026-10-16.json) records
six passing native cases plus the light/dark capture follow-up. Core was unchanged
and not repeated. The build syntax repair, fixture sheet overload and actual
unfolded-layout readiness correction are recorded, retaining all behavioral
assertions. All eight receivers, including the failed run, were reaped and
independently absent. Native event checks are distinct from physical input and
signed acceptance.

![Native merge-margin-selection-dark](site/assets/merge-margin-selection-dark.png)

![Native merge-margin-selection-light](site/assets/merge-margin-selection-light.png)
