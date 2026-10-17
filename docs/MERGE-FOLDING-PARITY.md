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


## Atomic folding and aligned-result expansion — October 17, 2026

A multi-row reveal now mutates each folded run once and publishes one complete
controller projection/expansion batch. TextKit fold application and restoration
use editing transactions, so storage observers do not receive a half-restored or
partially hidden map. Attribute restoration, original text coordinates and Undo
semantics remain intact. Result-to-source expansion uses shared source row
coordinates when the result has an aligned projection; serialized conflict-marker
rows are used only through exact anchors in the free-result fallback. Source and
result expansion now synchronize once per batch. Exact result anchor lookup uses
an offset-to-row index instead of scanning every result line for every anchor.

The native folding receiver now mounts its own invisible windows before checking
layout, matching production window attachment. It retains phase diagnostics for
transactions, layout, selection, combined mode, anchored/aligned expansion,
appearance and retirement. A timeout now prints bounded captured output tails
before the existing owned-process cleanup and rethrows the original timeout.
No timeout limit or behavioral assertion is relaxed. The earlier hosted timeout
is still unresolved until the new hosted result supplies evidence; these changes
do not establish its root cause.

The Debug build, all 23 focused Core checks and seven native-receiver ownership
contracts pass. The eight-case grouped native pass covers folding, wrapping,
wrapped navigation, block navigation, three-pane navigation, initial navigation,
Find and viewport ownership. Atomic apply/restore each emit one complete editing
notification; multi-run reveal publishes one projection/expansion batch. The native
regression expands the aligned result after serialized conflict markers and verifies
all matching source rows are shown without changing text, anchors, dirty or Undo.
Core also verifies 12,000 exact UTF-16 row anchors and invalid middle offsets.

The initial native fixture captured its baseline before AppKit substituted the
emoji fallback font. A focused diagnostic proved one notification but different
system font attributes. The fixture now normalizes its baseline with fixAttributes
before retaining it; strict full attribute restoration and all behavioral checks
remain. Core and the app build were not repeated. The aligned coordinate fixture was then strengthened to use a short section
between two conflicts; it proves the wrong serialized candidates cannot expose
the desired source range. Only that folding case was rerun and passed, with no
Core/build repeat. All eleven owned native receivers from the attempts were
reaped and independently absent. See [batch evidence](qa/merge-folding-transactions-2026-10-17.json).

The older hosted implementation passed its Git integration step, confirming the
earlier About test compiler repair, and progressed into native checks. A full
current implementation hosted pass and the earlier folding timeout root cause
remain open. Physical input, exact visual comparison, large-document end-to-end
performance and signed acceptance remain open.


## Hosted Collapse stall diagnosis — October 17, 2026

The completed b818417d hosted run passed all 1,809 Core tests (two skipped)
and the first ten wrapped-editor cases, then timed out at 300 seconds in folding.
The retained stderr ends at `pair loaded; collapsing`, before the fixture reaches
its TextKit measurement phase. Receiver 81749 was reaped. The same folding case
passes locally, so the blocked code and a production repair remain unproven.

The wrapped family now opts into a two-second stack sample of its own live
receiver after a timeout and before mandatory process-group cleanup. Sampling
has a separate ten-second command bound; its failure preserves the original
timeout. CI retains the stack file as a failure artifact. The family runs once
immediately after the Debug app build, allowing this known failure to report
before the full Core suite. No assertion, case or timeout was relaxed.
See [diagnostic evidence](qa/ci-folding-sample-2026-10-17.json).

A current universal Debug build and the same full folding case under x86_64
Rosetta also pass locally (receiver 11027). This is not a macOS 15 Intel hardware
reproduction. The nine receiver contracts pass; their initial ResourceWarnings
exposed captured pipes retained through timeout tracebacks. Explicit pipe closure
after reaping fixes that defect, and only those affected contracts were repeated.
No timeout/assertion was relaxed and no production Collapse fix is claimed.
