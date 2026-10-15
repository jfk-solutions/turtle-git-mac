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
