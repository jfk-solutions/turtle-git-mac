# Subversion merge engine adapter

TortoiseGitMerge's `DiffData.cpp` uses Subversion's diff engine. The existing
native source alignment still uses Swift line differences and the conflict
result still comes from Git `merge-file`; those UI paths are not replaced by
this backend batch.

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

Remaining integration: replacing pane alignment, regenerating three-pane results
with original text, filter selection/dirty reload/Undo workflows, resolved child
conflict regions, complete upstream options and EOL normalization, full libsvn
segmentation equivalence, native layout, physical and signed App Store acceptance.
The current protocol deliberately retains top-level conflict containers; it does
not yet export Subversion's resolved child graph. This is a backend foundation
for the complete port, not certification of a replacement editor.
