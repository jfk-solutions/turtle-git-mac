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
shorter current line can still compare against a longer opposite line. The existing
Swift inline matcher still differs from libsvn on ambiguous repeated-token ties;
adding navigation does not certify engine equivalence.

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

Physical shortcut/menu/focus/VoiceOver acceptance, complete current light/dark
window captures, exact libsvn token ties, all three-pane result states and
signed/minimum-OS acceptance remain open. No whole-editor or app certification
is implied.

The four diagnostic window captures were inspected and rejected because the
capture omitted some SwiftUI/native chrome. They remain under build/qa only; no
new screenshot was published from this batch.
