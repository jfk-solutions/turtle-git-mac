# Compare and Merge pane identity and status

Pinned source: `7338078f8ddd924b8cddee35f512f2286072136d`,
`TortoiseMerge/BaseView.cpp::DrawHeader` and header tooltip handling,
`MainFrm.cpp::OnUpdateColumnStatusBar/OnUpdateMarkedWords`.

Compare uses compact single-line pane headers with the source Removed/Added
palette. Three-way Merge uses neutral headers. Each header retains its pane title
and source description, prefixes a modified pane with `* `, and draws an active
focus edge. Literal titles and full paths remain available in native tooltips;
embedded tabs and line separators use visible symbols only in the bounded
caption. The document, path and saved bytes are unchanged. Colors use the owning
comparison's captured palette preferences and adapt to light/dark appearance.

Pressing a header focuses its actual editor. Readonly panes retain navigation and
status. Closed, detached or replaced owners, busy operations and open sheets
refuse activation. Captured callbacks cannot revive across Quit, reload, pane
exchange or optional Base replacement. Combined one-pane Compare follows the
active combined editor. Three-way Merge retains the independent result dirty
indicator and existing kept-source explanation.

The status bar reports the focused pane's one-based logical UTF-16 column,
matching the source caret view coordinate. A tab counts one character, a non-BMP
character uses two UTF-16 units, and wrapping does not reset the logical column.
Marked-word counts follow source order: `L` for left, `R` for right and `B` for
the bottom result. A separate optional Base preview is an additional native pane;
its marks do not replace the source bottom count. Changing the marked word can
change counts within the same line, independently of locator row highlights.
The existing View/Status Bar preference hides and restores these indicators.

Implementation is shared by `MergePanePresentation.swift`,
`FileComparisonWindow.swift`, `TextConflictWindow.swift` and
`MergeFindWindow.swift`. The
[dated grouped record](qa/merge-patch-family-2026-10-21.json) reports actual
validation attempts, repairs and captures. A fixture or this document alone is
not evidence of a pass.

Complete upstream command/state/layout parity, physical pointer/keyboard and
VoiceOver behavior, very large documents, all locales, minimum-version/Intel,
current installed signed workflows and complete hosted integration remain open.
The separate [patch application/save family](PATCH-SAVE-APPLICATION-POLICY-PARITY.md)
does not close the [source text-patch adapter gap](MERGE-PATCH-TEXT-ADAPTER-GAPS.md).

The October 23 grouped checkpoint passes all six case/engine pairs across the
three native scenarios, with twelve reviewed light/dark captures. The patch/Core
group passes 48 tests; a separate 59-test focused check covers actual hosted
assertion repairs. Failed attempts and their repairs remain in the dated record.
These scoped results do not establish complete upstream or signed acceptance.

## Pane-header context actions — October 25, 2026

The connected [header workflow family](MERGE-PANE-HEADER-PARITY.md) adds the
source **Show diff separately** and native Reveal/Save As routes with captured
pane/window/generation ownership. It distinguishes source three-pane behavior
from native two-pane and compact P4-style conveniences, and documents retained
source snapshots and saved-output identity. Its [separate evidence record](qa/merge-pane-header-2026-10-25.json)
will record the new grouped checkpoint; the earlier presentation passes above
do not validate these new actions.
