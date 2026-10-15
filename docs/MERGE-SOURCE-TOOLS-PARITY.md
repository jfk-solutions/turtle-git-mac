# Merge source-pane tools — partial native parity

Source pin: `7338078f8ddd924b8cddee35f512f2286072136d`,
MainFrm.cpp::OnFileSaveAs / DiffLeftToBase / DiffRightToBase and
BaseView.cpp::SaveFile / SaveFileTo.

The three-pane Save As menu now offers left, right and merged result. Source
context menus also offer Save this pane as and Compare with Base, with original
Save As/Compare icons. Left-source export retains removed Base rows; right skips
them. Empty alignment rows are not file content. Conflicted row groups retain
the source's literal `.mine`/`.theirs` marker serialization and NoEnding marker
behavior; exact Windows acceptance of those unusual bytes remains open.
Source encodings and original endings are retained by the captured export.

Source exports own a Save sheet, captured immutable bytes and the selected lease.
Cancel and retired owners refuse late answers. Active export work guards Quit;
source Open/Close are fenced during export. Successful source Save As now rebinds the pane, matching SaveFileTo.
Later source comparisons and Reload read the chosen file; source snapshots are
validated before merged Save. The selected lease remains with the owner.
See [Save As target behavior](SAVE-AS-TARGETS.md).

Compare Mine/Theirs with Base opens an independent native comparison, matching
the source's separate process. It uses private read-only captured stage files,
not a new checkout, repository or live source rewrite. Container temporary
snapshots receive narrowly checked internal access; generated-file grants and
private files live with that comparison window and are removed on close.

Merged-result copies from repository conflicts now use the same owned export
sheet and capture their selected encoding before presentation. Unresolved-marker
confirmation is owned and defaults to Cancel. Standalone output Save As retains
its existing guarded output/snapshot save workflow. Read-only source comparisons
refuse direct editing and transfers until that pane is explicitly saved to a
user-selected file outside its private snapshot directory.

Earlier copy-only validation passed: Debug build, 16 focused Core checks and one grouped native
source-tools/two-pane/three-pane receiver. The first compile found missing explicit
self references in the export Task; repaired before successful build/Core run.
The first native fixture requested emoji output in Windows-1252. Encoding failure
correctly prevented a panel/write; selecting UTF-16LE BOM repaired the fixture.
No application build or Core suite was repeated for that fixture correction.
The native checks verify actual left/right/result export bytes, owned Cancel and
late replies, Close/Quit gates, read-only captured source comparisons and private
snapshot deletion, with input files unchanged. Existing editor typing/selection/
Undo/Save and three-pane reload regressions passed. All owned receivers were
reaped. See [validation evidence](qa/merge-source-tools-2026-10-14.json).

Physical Save/Compare gestures, warning-button input/VoiceOver, exact captures,
complete conflict-gap/EOL equivalence,
signed/container grants and full upstream/application parity remain open.

The subsequent [source target batch](qa/save-as-targets-2026-10-15.json) records
source Save As rebinding, later Save/Reload and owner-approved Quit Save checks,
with remaining acceptance limits.
