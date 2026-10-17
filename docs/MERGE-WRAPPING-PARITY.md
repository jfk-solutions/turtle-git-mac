# Wrap long lines

Source baseline: `7338078f8ddd924b8cddee35f512f2286072136d`,
`MainFrm.cpp::OnViewWraplonglines`, `BaseView.cpp::WrapChanged` and
`BuildScreen2ViewVector/CountMultiLines`.

Both native text viewers now offer **View → Wrap long lines**, saved as
`TurtleGitMerge.WrapLines` with the source false default. Wrapping uses the
pane's actual width, font and tab settings. Horizontal scrolling is disabled
while wrapped and restored when unwrapped; horizontal offsets reset as upstream
does. Window/split resizing schedules a bounded layout update.

Aligned two-pane rows use the maximum intrinsic wrapped height across their
panes. Extra paragraph spacing fills the shorter side without inserting text,
so subsequent corresponding rows keep the same vertical position. The same
logic aligns the two source panes of a three-file merge. Combined and single-file
views wrap independently. The current three-pane result/marker layout wraps
independently: complete source-to-result row alignment remains separate open
work, as it did before this feature.

TextKit keeps logical UTF-16 selection, clipboard, Find, edit and Undo offsets;
wrapping does not change file text, comparison ranges, source line numbers or
encodings. The existing ruler labels logical lines once, and the locator derives
visible logical rows from glyph geometry. Owned frame/storage observers and
queued layout work retire with their viewer.

Native checks compare actual wrapped geometry, matching paired-row positions,
resize reflow and horizontal-scroll gates, plus text/selection/history/alignment
and saved-byte invariants. They cover one-pane and three-pane mode changes and
retired preference refusal. Source CString word wrapping and TextKit Unicode
word boundaries are not certified equivalent. Full continuation/background
styling, active-caret visibility, long-scroll anchoring, unchanged-section
collapse, high contrast, large-file performance, physical light/dark/keyboard
and signed/minimum-OS acceptance remain open.


## Evidence

Unsigned Debug builds passed. One fixture compilation linked the existing app
objects; all sixteen Merge receiver families passed in one process. The wrapping
receiver measured actual glyph-row geometry across differing source lengths
and after resizing, with text/selection/history/comparison/saved-byte invariants
retained. See [the batch record](qa/merge-wrapping-2026-10-12.json).
All test-owned windows/helpers closed. Full hosted and physical/signed
acceptance remain unproven.

## Ruler viewport follow-up — October 15, 2026

The conflict identity visual review found initial characters hidden under the
line ruler. The shared wrapping adapter now uses clip-view insets for leading
horizontal position and available wrapping width, retaining user offset when
ruler geometry changes. See [the connected family](CONFLICT-IDENTITIES.md).

[Grouped validation and visual review](qa/conflict-identities-2026-10-15.json)
record actual coverage and remaining limits; no dialog is newly certified.


## Wrapped navigation and viewport reflow — October 16, 2026

The current aligned result projection already supplies result cells to the shared
wrapping controller. All three aligned panes therefore participate in row-height
measurement; the earlier independent-marker-result description above is historical.
This continuation adds actual TextKit screen-fragment entry positions and owned
viewport reflow across both editor families.

Reverse difference/conflict entry uses the last actual wrapped fragment of its
logical entry row. Forward entry uses the first; two-pane inline advancement
still follows entry as upstream. A newly selected context block retains the clicked subline,
clamping the corresponding peer entry when that pane has fewer fragments. A context click inside an existing block retains its caret and block, as upstream. Source
and result block ranges remain logical UTF-16 selections independent of the caret.
Only the active pane centers linked scrolling, so different peer wrap counts
cannot race to recenter the group.

The wrapping owner caches settled row geometry and the visible row/fraction from
explicit wheel, key, mouse and native scroller input, and completed block, locator,
Find and Go to Line navigation. Automatic TextKit caret visibility during reflow
does not replace that reading intent. Pending reflow drains before new input. Width, font and wrap changes restore that reading position after all
shared heights settle. A text replacement invalidates the aligned group's saved
anchors; hidden fold rows refuse an obsolete anchor. Paragraph padding is included
in the reading fraction, so short-side alignment gaps do not select the next row.
Frame/storage/bounds observers share retirement, and pending geometry cannot
replace a captured anchor using partially reflowed layout. TextKit extents are
updated before scroll clamping. A real scroller-width change schedules a bounded
follow-up layout pass.

The source's screen-row state walk and no-wrap boundaries remain the baseline
(`BaseView::SelectNextBlock`, `SetupAllSelection`, `CountMultiLines`). TextKit
word boundaries and a native insertion caret inside a short pane's virtual
padding are not certified identical to Windows. Arbitrary multi-font/custom
paragraphs, extreme sizes, physical gestures, VoiceOver, minimum OS, signed scopes
and complete editor/application parity remain open.


The locator waits for settled shared geometry, and unchanged selection/viewport
values no longer republish the editor model or reschedule identical peer scrolling.
This avoids a native layout feedback loop when long wrapped rows reflow.

[Grouped validation](qa/merge-wrapped-navigation-2026-10-16.json) records seven
passing native cases after the repairs, including retained navigation, initial
entry, folding and Find. No Core changes or Core rerun were required. All owned
receivers were reaped and independently absent. These are local unsigned checks;
no complete hosted or physical/signed acceptance is claimed.

Actual three-pane captures show the wrapped sources at an unresolved conflict
whose aligned result cells are empty. They document this state, not complete
Windows visual parity.

![Wrapped merge sources, light appearance](site/assets/merge-wrapped-navigation-light.png)

![Wrapped merge sources, dark appearance](site/assets/merge-wrapped-navigation-dark.png)


## Complete native presentation transactions — October 17, 2026

Two-pane Compare and the three-pane Merge source/result renderers now commit
font, per-row colors, inline emphasis and the final fold map in one NSTextStorage
editing transaction. Restoring hidden attributes no longer publishes an
intermediate unfolded paragraph map before reapplying source presentation.
Synchronous aligned-result installation includes its initial fold restoration
in the same transaction too. Caret translation, block centering and geometry
measurement occur after that complete attributed snapshot commits. Selection
notifications caused by installing the presentation cannot reveal a stale fold
map or replace the pending model caret. User selection callbacks resume when
installation ends; text, source coordinates and document Undo remain separate.

This repairs a concrete partial-style publication gap in the native port. It is
not yet proof of the hosted wrapped-navigation/folding stall's cause. The local
pre-change wrapped-navigation baseline passed, while the older macOS CI job
timed out. The instrumented current run remains the authority for that gate.

[Batch evidence](qa/merge-presentation-transactions-2026-10-17.json) records the
grouped native scope and remaining physical/minimum-OS/signed acceptance.


The Debug build and all fifteen native cases passed at the grouped checkpoint:
twelve wrapped/folding/navigation/ownership cases plus Unicode typing and the
two-pane/three-pane editing engines. The new hosted-refresh observer checks saw
six and eleven complete storage notifications respectively, with no intermediate
fold map and unchanged text/carets. Every owned receiver, including the pre-change
baseline, was reaped and independently absent. Core was unchanged and not rerun.
This is local unsigned evidence; the active hosted run had not reached its editor
gate at the final observation, so hosted resolution is not claimed.

## Stable presentation and redraw — October 18, 2026

The hosted Intel timeout has an actual [captured stack](qa/ci-wrapped-stack-2026-10-18.json)
in AppKit/SwiftUI/TextKit layout and drawing. That evidence motivated a connected
presentation change; it does not by itself identify a deadlock or prove a repair.

Compare and Merge now build source styling off-storage and install it together
with its final fold map only when the source presentation changes. The shared
owner compares the unfurled attributed presentation, its font and fold revision;
it preserves live wrapping padding on identical hosting updates. Character edits,
including replacement by identical text, invalidate the checkpoint. Explicit fold
restoration also invalidates it. Dynamic source palette colors retain identity
until palette replacement and still resolve separate light/dark colors.

Wrapping reflows the group for actual storage, width, inset, enabled or alignment
changes. Identical registrations do not rewrite paragraphs or publish another
geometry callback. Scroller width changes still schedule a reconciliation pass,
and input retains the existing source-row/fraction and caret ownership rules.
Find preserves temporary paint on unchanged refreshes, but repaints after storage
styling/character edits, search/options, marked words/separators, layout-manager,
palette, appearance or base color changes. Marked words still paint before Find,
and hidden/marker rows remain excluded, as in the pinned source paint ordering.

The grouped receiver includes an explicit unchanged-update check alongside the
retained navigation, geometry, folding, Find, editing and ownership cases. Local
checks cannot establish hosted macOS 15/Intel resolution, signed behavior or full
visual parity; the current hosted failure remains a release gate until a passing
current run demonstrates otherwise.

The [batch record](qa/merge-presentation-family-2026-10-18.json) records the single
successful Debug build, 26 relevant Core passes with one expected parser-oracle
skip, and all 13 distinct native cases passing on the same app sources. Two
initial fixture issues were diagnosed: AppKit's residual dirty flag was replaced
by an actual invalidation-request count, and the synthetic wheel's delayed
30-pixel delivery is observed before beginning a separate reading navigation.
No behavioral assertion was removed. All 18 receivers across successful and
failed attempts were reaped and independently confirmed absent. No new visual,
hosted or distribution acceptance is claimed.


## Stable native pane and source presentation ownership — October 18, 2026

The hosted Intel/macOS 15 wrapped-navigation timeout persisted after the earlier
storage/Find no-op repairs. The retained [post-repair stack](qa/ci-wrapped-stack-after-presentation-2026-10-18.json)
still samples SwiftUI/AppKit layout and repeated source projection; it does not
prove a unique root cause or a deadlock.

Compare now gives each native split child one observing SwiftUI pane for its
lifetime. Parent updates no longer replace both hosted roots. The split controls
their frames and divider ratio, with child content-size negotiation disabled;
editor representables answer finite viewport proposals without growing their
requested size from wrapped document height. Resize, font, tab and wrap geometry
continue through the existing aligned reflow/reading-anchor owner.

Both Compare and three-pane Merge retain an immutable unfolded attributed source
and inline missing-character markers until exact source/peer bytes, line numbers,
state, font, tab width, inline mode/word mode/length cap, palette or pane mode
changes. A peer-only edit and canonically equivalent but byte-distinct text cannot
reuse stale inline paint. Folding revisions and real storage edits still pass
through the existing independent storage/fold installer. Whitespace preferences,
marked rows, numbers, moved links and actual reflow invalidate native drawing when
needed; an unchanged parent update does not repeatedly repaint every ruler.
Deferred viewport selection is coalesced and requested for pending navigation.

Pinned source comparison remains `CBaseView::WrapChanged`,
`CalculateWrappedLine`, `CountMultiLines`, scrollbar recalculation and source
size handlers in `src/TortoiseMerge/BaseView.cpp` at
`7338078f8ddd924b8cddee35f512f2286072136d`. Native SwiftUI/TextKit ownership is a
platform adaptation of those per-view wrapping responsibilities, not a claim of
identical Unicode word-breaking. No dialog controls or source command semantics
were removed. Physical rendering, hosted older-SDK/Intel timeout resolution and
complete large-file/format/keyboard parity still require their own evidence.

The grouped native checkpoint and any affected repairs are recorded in
[the pane presentation batch record](qa/merge-pane-presentation-2026-10-18.json).
