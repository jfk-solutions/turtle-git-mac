# Microsoft Word three-way merge

The bundled Word merge adapter ports the modern branch of TortoiseGit's
`merge-doc.js` for `.doc`, `.docx` and `.docm` conflicts. Microsoft Word must be
installed separately. It prepares a Word document with tracked merge changes;
TurtleGit does not flatten document content into a text editor.

New unsaved Merge Tool defaults include these associations. Existing saved
configuration remains authoritative. To restore them, use Settings → Diff Viewer
→ Merge Tool → Advanced → Restore Defaults, accept Advanced and Apply Settings.
Other associations remain. The program editor also offers Microsoft Word document
merge. Shift reverses the selected association/program's enabled state, as for
other merge tools. ZIP, binary-report and Mathematica adapters remain diff-only.

## Review and save

After the conflict inputs are prepared, an owned **TurtleGit Word Merge** sheet
explains the workflow and shows the full original conflicting path. OK creates
the Word merge; Cancel leaves the conflict unresolved. Word compares base against
theirs and mine with the source's selected-target, formatting and author options,
then merges theirs into the private mine document. Reject or accept changes in
Word and use **Save As** to save the result to the original conflicting path shown
in the instructions. Saving only the private mine document does not update Git's
working file. TurtleGit does not save over that original automatically.

With **Block while merging**, TurtleGit offers **Mark Resolved / No** after the
Word operation returns. No is the default. Complete the Word review and save first,
then explicitly choose Mark Resolved. TurtleGit revalidates the captured conflict
stages and stages the current original working file. No leaves the index alone.
Nonblocking mode leaves resolution to the normal Resolve workflow. Word supplies
no usable process exit status, so **Trust the exit code** cannot resolve a Word
merge. Saved stale settings requesting trusted Word status produce an error.

## Ownership and private files

Base/theirs/mine bytes are captured through the existing conflict preparation,
including rebase-side orientation and stage validation. Copies live in a private
folder, with distinct role-prefixed names so Word can open all three together.
They are editable for Word's tracked-revision operations; the repository's stage
blobs and real result remain independent. Arguments arrive as Apple-event string
descriptors. A filename never becomes AppleScript or shell syntax.

Word's automatic macro execution is suppressed while documents open, as in both
upstream Word scripts. Both comparison and merge handlers attempt to restore the
prior automation-security setting on success/failure; their worker is serialized.
Only owned private input references are closed. Word and unrelated user documents
are not terminated by TurtleGit cancellation.

Closing/cancelling before dispatch rejects late instruction answers and prevents
another Word operation. An already dispatched Apple event cannot be rolled back;
Quit remains blocked until its worker settles. Retired owners do not present a
resolution question or stage anything. Successful or uncertain Word receipts keep
private files through normal app cleanup, while confirmed unopened/denied failure
removes them. Saved Data's Temp files or OS cleanup can remove retained copies.

The existing Word Automation usage description/targeted AppStore exception also
covers this operation. Permission denial provides the System Settings recovery
hint. Word's own format, protected-document and file-access prompts still apply.
See [Word comparison](WORD-COMPARISON.md) for the target declaration and distribution
acceptance boundary.

## Acceptance still open

Core checks cover private editable stage bytes, distinct names, original-file
independence, defaults/Shift and invalid diff-only merge kinds. Native checks use
real local Git conflicts and the shipping dispatcher/questions, with an intercepted
Word executor to verify No, explicit saved-result staging, stale/closed replies and
worker/Quit lifetime. The optional terminology check compiles both fixed handlers
against the installed Word dictionary without executing Word operations.

Live Word output and exact tracked-change direction, macro suppression/restoration,
Save As interaction, all document formats, actual TCC/file grants, physical native
questions, signed Finder/AppStore and full source parity remain unverified.
LibreOffice/OpenDocument merge and PowerPoint workflows remain open. See
[Excel comparison](EXCEL-COMPARISON.md) for its separate adapter/acceptance scope.
