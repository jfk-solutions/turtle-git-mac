# Subversion merge engine adapter

TortoiseGitMerge's `DiffData.cpp` uses Subversion's diff engine. Native three-pane
conflict preparation now uses the pinned adapter for source alignment and
result generation. Two-pane comparisons now request pinned Subversion ranges too. A short-lived
Swift coordinate projection supports immediate native text/Undo updates while
comparison is pending; transfers, difference navigation and inline highlighting
wait for the authoritative result. Engine failures clear the comparison rather
than publishing that projection as a completed diff. The
Core API's legacy default Git path remains available for comparison tests; the
native conflict window requests Subversion explicitly.

`TurtleGitMergeDiff` now adapts the actual pinned Subversion diff2/diff3 APIs
into typed common/modified/latest/same/conflict ranges. It loads the private
per-CPU libraries already packaged for GitSVN instead of adding a second copy
of Subversion/APR. The adapter itself is universal, targets macOS 13 and links
directly only to system libraries. Packaging includes its GPL source, license,
reconstruction recipe, hashes and inherited sandbox signing configuration.
The dynamic libraries retain the separate SVN source/license/audit record.

The Swift entry point keeps original Base/Mine/Theirs line arrays alongside
engine ranges. Regex keys use the existing ECMAScript helper. Each source line
is hex-framed as one engine token, so nine EOL styles, embedded NUL and regex
replacements containing newlines cannot corrupt line counts. Original content
is never overwritten by comparison keys. Helper output is checked for contiguous,
bounded, complete mappings and valid segment kinds. Processes are cancellable
and bounded; private input files are removed after completion.

Three-pane integration retains original numbered source rows, display-only
removed Base rows, one-side gaps, identical changes and conflict colors. Common
and identical changes prefer original Mine text, latest-only changes use Theirs,
and conflicts retain the editor's marker-based representation. Regex selection
is window-local and uses explicit dirty Save/discard/Cancel before regenerating
from index stages. Cancel preserves the current result and Undo history. Successful
reload resets history; Save-before-Reload retains unresolved stages until a
separate Mark as resolved. Preparation, Close and Quit track owned cancellation.

Two-pane requests are debounced during typing and cancel superseded helpers.
Original-text source selections and marked/edited annotations are remapped when
Subversion publishes an alignment. Original source data and saved encoding/EOL
choices remain independent of comparison keys.

Remaining: resolved child conflict regions, complete
upstream options and EOL normalization, literal-marker handling, full libsvn
segmentation equivalence, native layout, physical and signed App Store acceptance.
The current protocol deliberately retains top-level conflict containers; it does
not yet export Subversion's resolved child graph. This is a backend foundation
and native three-pane integration for the complete port, not certification of
the full replacement editor.

Grouped integration evidence: 38 Core tests passed after a compile-time setter
access repair. The focused native receiver then passed production preparation,
regex rows, original Mine preference, Cancel/Undo, No Filter, discard and
Save-before-Reload, explicit resolution, unchanged HEAD and Close cancellation.
Its first Undo assertion was too early for AppKit's queued update; the repaired
fixture waits for the actual editable view and Undo state. Offscreen content
captures omitted SwiftUI toolbar text and were rejected. No new screenshots are
published from that method. All owned windows/helpers exited. The receiver is
included in the shared CI compilation; its new combined wrapper has not yet run
remotely. See `qa/three-pane-engine-integration-2026-10-12.json`.

Two-pane integration: 52 grouped Core tests and the focused native receiver
passed. Native checks cover Unicode typing/selection, Undo/Redo, marks, Include
semantics, exact BOM/CRLF saves and cancellation of a started adapter. A real
caret-handoff bug was repaired; the fixture's unmarked-save expectation was
also corrected. Original UTF-16 Base bytes and executable permissions remained
unchanged. See `qa/two-pane-engine-integration-2026-10-12.json`. Physical input,
complete captures and signed acceptance remain open.
