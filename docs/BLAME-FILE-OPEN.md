# Blame File Open and recent files

See [Blame menus and panes](BLAME-MENUS.md) for annotation context menus,
keyboard access, navigation and pane layout.

The pinned `TortoiseGitBlameENG.rc` File menu has Open, four recent files, Settings
and Exit. `TortoiseGitBlameDoc::OnOpenDocument` reuses the SDI document, defaults
subsequent Open to HEAD and adds only HEAD documents to MRU. Save/Save As strings
are unused standard resources; there is no active Blame Save/Export menu to port.

The native File menu now offers Open, Recent Files, Settings and Close. Open uses
an owned file sheet. A sandboxed file outside the current grant requests an owned
repository-folder sheet before Git discovery. Cancel or failed permission/Git reads
retain the current document, window and recent list. Preparing another document
blocks ordinary close and is counted for Quit. Cancel waits for owned readers to
settle before allowing another Open. Forced owner retirement cancels
owned Git processes, fences picker replies and releases prepared replacement data.

Successful preparation captures a pinned HEAD blob, blame annotations and history
before replacing the existing native window's content. Old source callbacks
retire; an existing modeless Find panel/draft rebinds to the replacement. The new model starts at line one and binds context commands to the newly
opened repository/access lease. The repository-model registry updates its identity,
retaining any other existing window for the same file.

The private four-file archive contains a scoped bookmark, relative repository/file
locations and a display path. It is atomically replaced with mode 0600. Only usable
successful HEAD documents are registered; historical entrypoints do not add to MRU.
A restored/moved scope is revalidated before reads, and successful reopening renews
its bookmark and keeps its record ID. Unavailable/corrupt registrations report errors
rather than permitting filesystem access or overwriting a corrupt archive.

Blame now reads the selected blob with rev-parse, literal NUL-delimited ls-tree and
cat-file, avoiding a diff of the entire repository tree for a single source file.
All blob/blame/history commands accept cancellation and retain exact source bytes.
HEAD documents retain their requested HEAD identity for Reload; their snapshots
remain pinned for displayed history. This keeps historical file reads and existing encodings while reducing work for
large repositories. Read-only commands never modify HEAD, index or working files.

Verification uses private roots/grants, typed native chooser replies and owned Git
helper processes. Physical picker input, real security-scope/MRU relocation and
signed sandbox/App Store acceptance remain open. Full File/Edit/View menu, recent
label fitting, native global menu responder routing and accessibility parity remain
unverified. This batch does not certify the complete Blame viewer.

Debug and AppStore builds and both distribution audits passed. The focused Core
scope passed collectively: 27 existing Blame/presentation checks passed in the
initial run, and the new direct-read/cancellation test passed after its fixture
accepted the established Git cancellation error type. That test holds/reaps each
of rev-parse, ls-tree, cat-file, blame and history reads and refuses a whole-tree
diff dependency. Only the failed Core case was repeated.

Eight grouped native File Open/Find/source/wrap cases passed with system and
packaged Git. Initial File Open verification compared directory URL strings with
and without a trailing slash; canonical-path comparison repaired the fixture while
retaining all replacement/permission assertions. Native coverage includes retained
Find drafts, HEAD Reload after a new commit, two owned paused-read Cancel/retirement
paths and simulated moved recent grants. Process/window ownership and detailed
limits are in [batch evidence](qa/blame-file-open-2026-10-13.json). No new screenshot
or complete global-menu/registry/signed acceptance is inferred from these checks.

## Zooming and reading a line's revision

Use **View → Zoom In**, **Zoom Out** or **Actual Size** in Blame. The shortcuts
are Command-Plus, Command-Minus and Command-0. Command-Equals also zooms in.
Command-wheel, Control-wheel and trackpad pinch work over source and attribution.
Zoom changes both together, including wrapped rows, and keeps your selection and
scroll location. It applies to the current document; Actual Size restores the
font configured in Blame settings without changing that setting.

Hover a source line or its attribution to read its full revision, author/email,
date and message preview. Different origin filenames are included when relevant.
Long messages are bounded, and the preview follows the hovered line rather than
the current selection. The [source comparison](BLAME-PRESENTATION-INTERACTION-PARITY.md)
records the implementation scope and remaining physical acceptance.
