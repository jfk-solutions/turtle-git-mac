# Comparison common records and moved intervals

Source pin: `7338078f8ddd924b8cddee35f512f2286072136d`,
`DiffData.cpp::DoTwoWayDiff`, `CompareWithIgnoreWS` and `StickAndSkip`.

The engine plan now captures its comparison options alongside the original input
lines and filtered keys. Two-pane common-record presentation uses that captured
whitespace mode, rather than current preferences, to decide whether a Normal row
is hidden by comparison. Equal payloads are hidden even when their EOL differs.
Regex/case/comment differences retain FilteredDiff and remain shown in two panes.
The source's provisional Whitespace assignment is reset to Normal before its
filter classification; the port retains that behavior instead of adding a new
visible whitespace state here. Combined neutral aliases retain their separate
source conditions and visibility.

An unsplit common record in combined view now uses Mine's text and Base's exact
ending, following the source AddData call. This includes all nine recognized
styles. Split RemovedWhitespace/AddedWhitespace records retain each side's own
ending. Two-pane input records, original encodings and the unedited Mine draft
stay independent. Explicit combined export serializes its captured records using
Mine's selected encoding. Editing adopts those records through the existing
in-place history/save path; merely viewing or exporting does not write inputs.

With moved blocks enabled, adjacent contiguous modified intervals are joined
before pairing, following StickAndSkip. The restored whole interval determines
row pairing, gap placement and the navigable changed block; move detection still
uses the original plan. Disabling moves retains separate intervals. Malformed
ranges/common lengths and cancelled presentation work refuse publication.

[Grouped evidence](qa/merge-common-records-2026-10-16.json) records 70 passing
focused Core checks, including all 81 recognized ending pairs and the retained
pinned moved-block corpus. One Debug build passed with one exit-zero/no-output
compiler diagnostic. Four actual native workflows passed on the first grouped
attempt: common records, retained whitespace, EOF and moved blocks. One cached
receiver compilation links the built app; all four owned processes were reaped
and independently absent. Help remained byte-identical to the built bundle; the
website renders 261 documents with no unresolved fragments. No new screenshots
were needed for these record/serialization changes.

This does not certify complete DiffData/source
engine equivalence, every physical gesture, large-file behavior, minimum macOS,
VoiceOver or signed Finder/App Store acceptance.
