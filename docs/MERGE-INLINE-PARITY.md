# Inline differences and navigation

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`BaseView.cpp::GetLineColors/GetInlineDiffPositions/GetNextInlineDiff/GetPrevInlineDiff`,
`MainFrm.cpp::OnViewInlinediff/OnViewInlinediffword`, and `SVNLineDiff.cpp`.

The two-pane viewer and three-pane conflict editor expose Inline diff and Inline
diff word-wise with original TortoiseMerge ribbon artwork. Visibility reads and
saves `TurtleGitMerge.DisplayBinDiff`, default true. The audited source loads the
registry default but its toggle handler changes runtime state; remembering a
native toolbar change immediately is an explicit macOS persistence choice. Word mode stays local to the
viewer session, matching the upstream frame's runtime switch. Busy, preparing,
retired, single-file and attached-sheet contexts gate the applicable commands.
Toggling display does not regenerate source text or clear editing history.

Three-pane source rows now paint the matched portions with the modified palette
and the changed portions with inline added/removed colors, following the current
row state. The current source row and opposite source row remain aligned, with
original UTF-16 text, numbering and ending metadata. Missing-character ticks are
an overlay rather than inserted text. Normal, filtered and empty rows retain
their ordinary colors. Result-pane content remains editable through its existing
conflict/locator projection; this adds source-pane inline painting rather than a
new result alignment engine.

The maximum inline length applies to the current displayed line, as in source
GetLineColors. A shorter line can compare against a longer opposite line while
the longer pane suppresses its own inline painting. This also corrects the
previous two-pane/combined/line-bar cutoff that excluded both sides together.
Caches invalidate for new alignment, word mode and the relevant length setting.

Two-pane inline navigation visits each modified chunk's start and end on the
current caret line. Zero-width insertion/deletion positions participate. It uses
strict direction comparisons, never wraps to another line, and moves a caret
without selecting text or editing it. Navigate/context commands use the original
orange-dot artwork; Control-Option-Right/Left are the native equivalents of the
source Control-Alt shortcuts. Commands check the actual pane and current gates
again at execution, including stale menus.

As upstream, inline navigation is unavailable with the merge-result pane visible
or in a combined view without live opposite data. Source painting remains
available in a three-pane layout. Navigation is independent of the smaller saved
painting cutoff, and suppresses comparison when both lines exceed 100000 UTF-16 units. A
shorter current line can still compare against a longer opposite line. The shared matcher now calls the bundled Subversion 1.14.5 `svn_diff_diff_2`
in process, using source-compatible UTF-16 character/word tokens, word Adler32
hashes, callback ordering and the source similarity gate. Compare panes, combined
view, three-pane source painting, the line preview and inline navigation consume
the same result. Repeated-token ties no longer come from Swift
`CollectionDifference`. Each call owns its APR pool and callback context; no
per-line process is launched. A missing runtime or engine failure suppresses the
inline projection rather than substituting another matcher.

The packaged app loads only its own private architecture-specific runtime.
Standalone development receivers can use the companion Debug app; SwiftPM tests
can use the checkout runtime. App Store builds never use the checkout fallback.
The library remains loaded for process lifetime. Existing runtime embedding and
signing must include it; hardened/sandboxed acceptance of this new in-process
consumer remains open.

Word classification uses Foundation alphanumerics for individual UTF-16 units
and the source space/tab rule. Windows `IsCharAlphaNumeric` locale behavior is
not certified equivalent for every Unicode unit. The independent word oracle
therefore covers ASCII; Unicode units, combining text, surrogate pairs and NUL
are included in character-mode coverage. This does not certify all source-locale
word classifications or equivalence to every vendored Subversion revision.

The shared missing-character drawing uses TextKit's current glyph origin and
line fragment geometry, including wrapping. Source panes use the same native
light/dark palette and saved customization as the rest of the editor. Four
unchanged upstream bitmap resources and their hashes are in the icon provenance
manifest.

## Verification and remaining work

The grouped Merge receiver includes `merge-inline-native-2026-10-14.swift` with
existing two/three-pane engine, clipboard, locator, save, colors, Find, wrapping
and context families. The inline case uses actual hosted text views and private
files/preferences, checks chunk caret endpoints and token mode, saved visibility,
combined refusal, attributed source colors, light/dark appearance, cache limits,
retirement and unchanged text/selection/history/files. The dated QA record reports
actual execution results separately.

`scripts/test-inline-source.py` compiles the pinned original `SVNLineDiff`
parser, hash and callbacks after explicit Windows UTF-16 type adaptation. Source
Git blob hashes are verified before compilation. It compares 1,803 line pairs
against the Core bridge, public UTF-16 ranges, missing markers and similarity
gate; 160 concurrent comparisons check independent contexts.
`scripts/test-inline-native.py` groups the existing inline native family with
repeated character/word tie cases in both directions, native caret stops, actual
source and line-preview attributes, Aqua/Dark Aqua and unchanged files/Undo.
Results and any repairs are recorded in the dated QA record.

Physical shortcut/menu/focus/VoiceOver acceptance, complete current light/dark
window captures, all three-pane result states and
signed/minimum-OS acceptance remain open. No whole-editor or app certification
is implied.

The four diagnostic window captures were inspected and rejected because the
capture omitted some SwiftUI/native chrome. They remain under build/qa only; no
new screenshot was published from this batch.

## Hosted final-record fixture repair — 17 October 2026

Hosted run `39066931716` completed with a failure in the repeated-source pane
lookup after its 1821 Core cases passed (two skipped). The retained fixture
expected one native display LF for an ended one-line file. The source final
NoEnding-record port deliberately presents a second, empty row. A diagnostic
run confirmed exact loaded strings with two display LFs, both models settled
and no model error. This was an obsolete fixture expectation.

The grouped inline fixture now separately checks the terminal record (normal,
empty, source line 2), exact two-row native display and unchanged one-LF source
text/files. Preferences are supplied before hosting, and pane lookup awaits
exact attached source strings rather than view count alone. All source-oracle
ranges, caret stops, preview/native colors, Aqua/Dark Aqua and Undo/data assertions
remain. The affected grouped native recheck passed; both attempted receivers were
reaped and independently absent. No app/Core change, rebuild or full-suite repeat
was needed. [Dated evidence](qa/inline-presentation-repair-2026-10-17.json) retains
the initial failure and scope. This does not establish a passing current hosted
workflow or complete editor parity.
