# Applied-filter feedback and complete command/hover presentation — October 20, 2026

Source baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/Resources/TortoiseProcENG.rc::IDR_REVISIONGRAPH`,
`src/TortoiseProc/RevisionGraph/RevisionGraphDlg.cpp::OnViewFilter` and
`RevisionGraphWnd.cpp::TooltipText`.

The File/View popup commands now retain the resource's separator groups, with Find
alongside Filter as the native addition. View commands reuse the pinned
`IDR_REVGRAPHBAR` tiles; Save, Compare, Unified Diff and Help use the shared original
command artwork. The owning application-menu icon preference controls these
popup images independently of the always-visible toolbar and is reread for each
menu opening, so Settings changes apply to existing Graph windows. Command-plus/minus and
Command-F appear as native menu equivalents and continue through the same guarded
dispatcher. F5 requires an unmodified key; Option/Control combinations fall through
to AppKit. Shift used to produce the plus glyph remains supported.

`RevisionGraphDlg.cpp::OnViewFilter` checks both Filter representations when any
From, To, Current Branch or Local Branch scope is applied. The native controller
now derives menu and toolbar marks from those accepted options. Unaccepted sheet
text does not set the mark, Cancel preserves the prior state, and Reset clears it.
Modal ownership still disables competing commands; a displayed checkmark does not
bypass operation or sheet guards. Filter and Overview use an explicit rounded
native accent background/outline for their persistent checked state, independent
of pressed-state highlighting. The original toolbar icons remain unchanged;
disabled and increased-contrast appearances retain a distinct mark.
Existing `DialogGeometry.attach` already supplies
the app's installed window persistence and remains unchanged.

`RevisionGraphWnd.cpp::TooltipText` supplies the hover contract: hash, full author
and email, author time to local minute precision, then subject/body with their
original line separation. The native canvas now uses the captured graph metadata
for all those fields rather than omitting email and exposing raw ISO date text.
The source's 8,000 UTF-16-unit bound is retained without splitting a surrogate pair;
AppKit supplies screen fitting and wrapping. Closed, busy or modal-blocked canvases
refuse stale tooltip callbacks. Source font metrics and Windows tooltip lifetime
remain platform adaptations, not pixel-parity claims.

The grouped native fixture is
[`graph-presentation-native-2026-10-20.swift`](qa/graph-presentation-native-2026-10-20.swift).
It checks actual popup icons and owning preference changes, separator/accelerator
metadata, accepted range/reset and all four filter predicates, modal command
refusal, real graph author/body metadata, date conversion, bounded Unicode text,
canvas callbacks and owned closure. Offscreen AppKit rasters compare actual checked
and unchecked perimeter pixels outside the source icon for both Filter and Overview
in light/dark and enabled/disabled appearances; state-property assertions alone
do not establish visible feedback. Validation results are recorded by the batch
checkpoint; this implementation description alone is not a pass claim.

Full source window/layout, physical keyboard/pointer/accessibility, installed signed
Finder and distribution acceptance remain separate requirements. This family does
not certify complete Revision Graph or application parity.

## Native checkpoint

The Debug app and scoped native family checks passed with Apple and bundled Git
across the grouped checkpoint and focused repairs. The
[batch evidence](qa/history-editor-presentation-2026-10-20.json) records exact
checks, initial failures, repairs, captures and process cleanup. Core code was
unchanged and its suites were not repeated. This local result does not prove a
complete hosted CI pass, full source-window parity or signed distribution.
