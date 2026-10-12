# Clipboard patches and target matching

Source: `CPatch::CheckPatchPath`, `CountMatches`, `CountDirMatches`, the
better-target TaskDialog in `MainFrm.cpp`, `TrySavePatchFromClipboard` and the
registered `TGIT_UNIFIEDDIFF` format at
`7338078f8ddd924b8cddee35f512f2286072136d`.

Copy Patch in the native diff viewer exports the original `UnifiedDiffDocument`
bytes. The macOS `org.turtlegit.unified-diff` data type and a qualified TortoiseGit compatibility UTI
both carry those exact bytes; the literal Windows registered name is not a valid
macOS UTI. Ordinary text supplies a display/interoperability
representation. Read-only legacy/BOM/binary bytes are not replaced by decoded
display text. The app declares its data UTI in Info.plist.

The File menu's Review Clipboard Patch captures the clipboard once, on the
explicit action. Custom data takes priority over text. Copied plain diff text is
also accepted on that explicit command; arbitrary prose is rejected. Menu
construction does not poll clipboard contents. The captured bytes are passed
directly to the review workflow, which asks for a target folder but does not
require a fabricated source-file grant or create an external source file. A
clipboard change while the target chooser is open does not replace the source.
The app's active repository is not adopted or changed by this workflow.

Single-patch preparation now obtains Git's byte-oriented preimage statistics
for target matching, including rename preimages. It retains the source search
order: current folder, ancestors, immediate non-administration subfolders, then
ancestor directory matches for newly added files. A match requires strictly more
than integer `fileCount / 3`, rather than one file or a simple majority. macOS
sorts immediate children for repeatability and skips symlink directories and
paths escaping the candidate root. Sandboxed ancestor searches stop at the
largest real retained grant covering the selected target.

A different match opens an owned Suggested / Selected / Cancel choice before
changing the review target. The selected target is checked against its real
grants again, and repository facts are queried for that target. A Keep Selected
response opens the original folder even if the patch cannot apply there; it is
not silently redirected. Git-style a/b headers start at strip count 1, while
plain unified paths start at 0, matching the source's prefix handling. Manual
strip/reverse controls remain available in the existing review dialog.

Preflight Git commands now receive owned cancellation, and the matcher checks
cancellation between candidates. Forced closure cancels its process group and
fences late chooser/suggestion replies; the existing load counter blocks Quit
until cleanup finishes. Opening, matching or copying does not apply the patch.
Only the review's existing explicit Apply/Save operations change target files.

Still open: complete mixed-prefix/format behavior, source Open dialog accessory
integration, Finder clipboard routing where the source command is exposed,
physical prompt/layout comparison, public clipboard privacy UX and signed
bookmark/target acceptance. The ordinary Finder single-patch source clauses
remain unchanged. This batch advances the existing review port rather than
certifying all TortoiseGitMerge functionality.

Grouped validation: the existing 26 directory/review/viewer cases passed; all
five target-matching cases passed after repairing a path-alias issue and a
directory-URL assertion. Debug builds completed with existing diagnostics.
The final combined native receiver passed exact-byte pasteboard round trips,
snapshot retention across clipboard replacement, suggested/selected folder
choices and real plain-directory patch application. It used a private named
pasteboard and disposable targets, then exited and cleaned up its resources.
See `qa/clipboard-target-batch-2026-10-12.json` for repair history and limits.
