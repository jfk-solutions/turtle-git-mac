# ZIP archive comparison

ZIP comparisons can show a read-only list of the archive's top-level names,
modification dates and uncompressed sizes in TurtleGitMerge. This ports the
bundled TortoiseGit `diff-zip.js` workflow to macOS. It compares metadata, not the
contents of individual archive members. A content change with unchanged name,
date and size is therefore not detected by this view, matching that script.

New Diff Viewer settings use the bundled ZIP association. Existing saved
associations are preserved. To enable or restore it, open Settings → Diff Viewer →
Advanced → Restore Defaults, then accept Advanced and Apply Settings. Restore
Defaults restores the bundled archive, binary, notebook and Word document
associations, retaining other entries. See [bundled comparisons](BUNDLED-COMPARISONS.md).
Cancel in either settings owner preserves its prior saved value. An association
can also select ZIP archive inventory in its program editor. External programs
and disabled associations keep their usual matching and Shift behavior. Hold
Shift when opening the comparison to bypass an enabled ZIP inventory association
and inspect the original archive bytes with the regular internal viewer.

The native reader uses the ZIP central directory, including ZIP64 sizes, UTF-8,
CP437 filenames and valid Unicode path extra fields. Implicit folders are grouped
at the top level; explicit directory metadata takes precedence. Dates use the
stored ZIP DOS timestamp as `yyyy-MM-dd HH:mm:ss`, without inventing a time zone.
Archive order is retained; Windows Shell's locale-specific display and exact
folder-size presentation are not reproduced. Newlines/tabs in member names are
escaped for the listing. No archive member is extracted, opened or executed.
The reader limits metadata/text to 64 MiB and the directory to 100,000 entries.
Split archives and malformed directories report an error in the initiating
comparison window. Encrypted members can still contribute visible directory
metadata; their contents are never decrypted.

Historical and working-file comparison routes share the same association. The
inventory viewer receives immutable text with `.inventory.txt` names and no
editable file mode. Save/edit operations cannot retarget the original archive.
Reload reuses that captured inventory; reopen the original comparison to read a
changed archive. An absent side is represented by an empty absent-file pane.
Cancellation and initiating-window closure reject a late prepared inventory;
active preparation participates in the normal application Quit guard.

The remaining Windows Office/OpenDocument comparison/merge scripts still need
macOS adapters; see [Word comparison](WORD-COMPARISON.md) for its new native route. Binary and Mathematica adaptations are documented separately. This feature does not establish full document-tool, dialog or
App Store parity. Physical native interaction, Finder handoff, signed sandbox
access and large/exotic archive acceptance remain open.
