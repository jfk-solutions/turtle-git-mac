# Collapsed comparison view — partial native parity

Source: pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`DiffData.cpp::HideUnchangedSections`, `MainFrm.cpp::OnViewCollapsed` and
`BaseView.cpp::OnLButtonDblClk`.

The shared folding engine now implements source Shown/Hidden/Marker states,
context processing, marker ranges, shared expansion and navigation reveal.
Collapsed defaults to false; source ContextLines defaults to one and its saved
DWORD -1 sentinel retains all context. Marker expansion affects the shared map
for all panes. A pane-neutral projection retains source indices and explicitly
marks placeholders; source documents are never rewritten by folding.

The native window controller holds saved collapse state, the synchronized
projection, manual expansion, fresh alignment/context changes and retirement.
Repeated hosting updates retain expansion until alignment or context changes.
The two-pane/combined editors and three-pane source/result views now consume
fold visibility through their attributed layout. Native View menus expose
Collapsed. Full text/UTF-16 coordinates remain in text storage: hidden paragraphs
use subpixel height, and the original marker row draws the source `{...}` and
horizontal divider. Placeholder strings never replace document contents.
Double-click expands source markers through the shared source controller.
Find/Go To Line and other scroll-range requests reveal their destination before
scrolling. Folding suppresses whitespace/inline ticks and ruler numbers on
hidden/marker rows, and wrapping retains hidden-row heights.

The merge engine now emits exact common-row anchors into the initial result.
Result presentation carries them through edits and Undo snapshots. An anchor
shifts with preceding edits or is invalidated when its content is replaced;
repeated text is never used to guess a replacement anchor. Result visibility
projects the shared source map through those anchors. Result expansion reveals
both source panes, and source expansion refreshes the result projection. If an
edit removes a marker anchor, the surviving hidden result run receives an
expandable marker. Changed/conflicted/edited result lines remain shown.

Native context menus and accessibility custom actions expose Expand unchanged
section. Busy/preparing/retired owners refuse expansion. Find, Go To Line and
scroll-range navigation reveal their target before native layout/scrolling.

The connected implementation is now at its grouped validation checkpoint:
Core folding/result/engine/editing regressions, one Debug build, then one native
folding/wrapping/two-pane/three-pane editor group. Physical input, VoiceOver,
large-document performance, exact screen geometry versus Windows, and signed
App Store acceptance remain open. The fallback non-Subversion alignment has no
result anchors; its result stays visible rather than guessing positions.

The final Debug build and 39 focused Core checks passed. One grouped native
receiver passed folding, wrapping and the existing two/three-pane editor families.
The initial compile failed because the whitespace drawing helper referenced a
text view outside its scope; it now reads attributes from its layout manager.
The initial native fixture incorrectly required a newly prepared standalone
merge to be clean. Its corrected assertion verifies unchanged initial dirty/Undo
state. That fixture repair did not repeat the app build or Core suite.

The native checks measure actual TextKit collapse height, retain full view text,
verify hidden navigation reveal in both panes, combined mode, exact engine
anchors and synchronized expansion, busy/retired gates, accessibility action
presence, both appearances and unchanged input bytes. Existing regressions cover
wrapping/resize, Unicode typing/selection, Undo/Redo, marks, BOM/CRLF saves and
merge Save/discard/Cancel/reload. Both owned receivers were reaped. Appearance
switching and accessibility action presence do not prove visual matching or
actual VoiceOver behavior. See [validation evidence](qa/merge-folding-2026-10-14.json).
