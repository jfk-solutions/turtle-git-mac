# Microsoft Word document comparison

The bundled Word adapter opens a new Microsoft Word comparison result with
tracked text and formatting changes. It ports the modern Word branch of
TortoiseGit's `diff-doc.js`; it does not flatten a document to plain text.
Install Word separately, or install LibreOffice with its bundled Python runtime.
When Word is unavailable, this comparison association automatically tries the
[LibreOffice adapter](LIBREOFFICE-COMPARISON.md), following the source fallback.
Permission denial, an ambiguous Word result or a timeout does not dispatch a
second comparison. The adapter is offered for `.doc`, `.docx`,
`.docm`, `.dot`, `.dotx` and `.odt`. Actual format conversion is performed by Word.
[PowerPoint comparison](POWERPOINT-COMPARISON.md) has a separate native slide
review; shape-level revision decisions and editable merged output remain open.
[Excel comparison](EXCEL-COMPARISON.md) has its own native adapter.
[Word merge](WORD-MERGE.md) now has its own three-way workflow.

New unsaved Diff Viewer defaults include the five DOC/DOCX/DOCM/DOT/DOTX associations. ODT now defaults to LibreOffice; Word remains explicitly selectable for it. Existing saved
settings remain authoritative. To restore the bundled associations, use Settings
→ Diff Viewer → Advanced → Restore Defaults, accept Advanced, then Apply Settings.
Other associations remain. The program editor can select Microsoft Word document
comparison explicitly. Hold Shift when opening a comparison to bypass an enabled
Word association and retain the regular internal byte/text view.

The compared historical/working bytes are copied exactly into separate private,
read-only files retaining their filenames. Like upstream's modern Word branch,
Word opens the base and compares it against the new document, using a new result,
author `Comparison`, formatting detection and ignored comparison warnings. The
result is marked saved to avoid the source's unwanted Save As prompt only after
the handler identifies a new result window/document. Ambiguous identity reports
an error and retains possible results. It never marks the active document saved
merely because it is active. Outline view is normalized to normal view before
comparison; master/reading view is normalized only without subdocuments, matching
the source condition. Only the private input document opened by that call is closed. The original repository files are not modified. Existing document names and
window IDs are excluded from result selection; see the concurrent-window
acceptance limitation below. Automatic macros are suppressed
during input opening, as in the source. The handler reads back the disabled
setting before opening inputs and verifies restoration of the prior Word
automation-security setting on success and failure. An unconfirmed restoration
is an error, and captured files are retained for an uncertain handoff. Other Word preferences are
not changed.
TurtleGit does not accept/reject tracked changes, save over the originals, stage
files or mark a conflict resolved through this diff adapter.

Paths are passed as Apple-event descriptors to a fixed handler. Quotes, Unicode,
spaces and source-like text inside a filename cannot become script syntax; no
shell interprets them. Preparation runs off the UI thread. Cancellation before
Word dispatch suppresses it. During automation, a private cancellation marker
allows the handler to stop between Word commands, close proven private inputs
and restore security; an in-flight Word command cannot be rolled back. The owning operation and Quit guard last until its worker settles, including
a reply after the original dialog closes. Retired owners do not show stale errors
or open replacement windows. Word itself is never terminated by cancellation.

## Permission and failures

macOS can ask to allow TurtleGit to control Word. If denied, enable it in System
Settings → Privacy & Security → Automation and retry the comparison. A missing Word installation removes its unused private copies before trying
LibreOffice. A compile failure or confirmed denied/unopened request also removes
unused Word copies. If LibreOffice is unavailable, its own installation/runtime
error is shown; Word merging does not use this fallback. Success or a failure that might have opened documents
retains them so a receiving Word document cannot lose its input files. Settings
→ Saved Data → Temp files or OS temporary cleanup can later remove those copies.
If a comparison error remains visible, dismiss it before retrying normally.

The app's Automation usage description covers Word comparison and Apple Mail
composition. The installed Word scripting dictionary declares no scripting access
groups, so the AppStore preparation configuration requests the narrowly targeted
`com.microsoft.Word` Apple-event temporary exception, alongside the existing
compose-only Mail scripting target. This follows Apple's
[temporary exception documentation](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html).
Apple requires information about each such exception in
[App Store Connect](https://developer.apple.com/help/app-store-connect/reference/app-uploads/app-sandbox-information/).
The source declaration is not proof that signing, sandbox execution or App Review
has accepted it. Word's own file-access/format/security prompts still apply.

## Evidence and remaining acceptance

Core checks cover exact snapshots, private permissions/names, cancellation,
association/Shift behavior and retention policy. Native workflow checks use the
shipping comparison dispatcher and literal Apple-event arguments, with an
intercepted Word executor to avoid operating on user documents or accepting
Automation prompts. The optional local terminology check compiles the fixed
handler against the installed Word dictionary without executing a comparison.

New-window identification is conservative, but it is not a provenance receipt
from Word: concurrent user-created/closed windows can still make result attribution
uncertain. Physical acceptance of that case remains open.

Live Word output, track-change direction, all formats/converters, protected/macro
documents, TCC and Word file-access dialogs, full error/timeout variants, physical
interaction and signed Finder/App Store acceptance remain unverified. No complete
Word, document-tool, dialog or application parity claim follows from these checks.
