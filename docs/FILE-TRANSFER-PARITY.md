# Clipboard and Copy/Add transfers

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`,
`Commands/PasteMoveCommand.cpp`, `PasteCopyCommand.cpp` and `DropCopyAddCommand.cpp`.

## Native workflow

Commit and Working Tree file menus provide Copy files (actual file URLs),
Copy and Add, Paste Copy and Add, and Paste Move with original app icons.
The application Edit menu also opens the copy picker or captured clipboard workflow.
Focused Commit and Working Tree callers retain their repository rather than following
later workspace selection. The Copy/Add window accepts native file/folder selection,
file URL drops and a same-working-tree destination picker. It retains geometry.
The native window is a macOS entry-point adaptation of Explorer's destination menu.

Paste Move resolves every captured clipboard file to a versioned path in the same
working tree before enabling Move. It uses the shared collision name prompt and
`git mv` execution, preserving separate staged/working data. Its errors abort the
sequence, matching the active upstream Paste Move branch. Upstream's unversioned
and cross-repository move-and-add branch is disabled; TurtleGit does not enable it.

Copy/Add accepts sources outside the destination repository. Self-copy offers a
Rename-style sheet with inline validation. Existing files offer Overwrite, Keep or
Cancel; Keep stages retained contents. Existing directory-to-directory copies are
skipped, matching DropCopyAdd. Recursive copies preserve symlinks without following
them. Source-tree and destination metadata are revalidated after prompts and copying;
these checks do not provide a filesystem transaction. A temporary sibling prevents
a failed file copy from destroying an existing target before replacement.

Copied repository or submodule metadata offers Delete, Ignore or Abort. Delete
removes only the copied .git entry, then inspects remaining nested repositories.
Ignore excludes that copied repository's descendants from staging. Abort retains
copied files without beginning Copy/Add's final add phase. Administrative entries
are never passed to Add. Copy/Add stages after copying its batch; Paste Copy stages
per item. Both use ordinary literal `git add --`, retain ignored-file errors, stream
bounded output and preserve copied files when staging fails or is cancelled.

Owned source permission leases, destination access, child prompts, file URL provider
reads and operation counters remain alive until their work settles. Closing an owner
cancels its work and suppresses late callbacks. Source files remain untouched; these
commands do not commit. Git cancellation and directory-copy traversal check the
owned token. A single FileManager file copy is not interruptible internally; its
scope and active counter remain retained until that copy returns.

## Intentional adaptations and remaining acceptance

Paste Copy uses the explicit collision choice shared with Copy/Add rather than
Windows CopyFile's implicit overwrite. Native copying also supports folders and
preserves link identity. The result remains visible for Close and recovery instead
of automatically ending shell progress. Directory ACL/extended-attribute fidelity,
physical source/destination picker and drag gestures, keyboard/light/dark layouts,
all focused-menu states and signed sandbox grants remain unverified.

Finder clipboard folder menus now have a separate implementation and acceptance
record in [Finder transfers](FINDER-TRANSFER-PARITY.md). Finder drag-destination
menus remain unimplemented.
Complete Finder delivery, source-shell menu masks and remaining copy consumers are
still open. Commit's existing direct Add drop path is unchanged; Copy/Add drops go
through the dedicated copy window. No full upstream or App Store parity is claimed.
The Debug build, 17 related Core tests and four native cases with system and
bundled Git passed. Initial compilation required three integration repairs; no
Core tests executed until those repairs finished. All native receiver processes
were reaped. The unsigned private pasteboard fixture emitted a sandbox-extension
diagnostic, so this does not verify signed grants. See
[batch results](qa/file-transfer-2026-10-14.json).

Workspace and Working Tree local URL drops now offer the active pinned transfer
choices and route captured external sources to Copy/Add. See
[dropped-file transfer parity](FILE-DROP-TRANSFER-PARITY.md).

## Exact Move/Copy/clipboard/drop identities — October 17, 2026

The connected transfer continuation retains byte-exact source order through
Copy/Add, Move, clipboard file URLs, captured Finder requests and dropped providers.
Native source lists use exact Git identities, so Unicode peers occupy separate
rows. Repeated identical paths still deduplicate. Source authorization matches
selected URLs once each in captured order; a unique filesystem spelling can
match one source, while ambiguous peers cannot borrow or duplicate a grant.

A shared index-prefix catalog resolves filesystem-returned spellings only when
the index supplies one identity. Move/Rename refuse ambiguous source subtrees
before mutation. Copy/overwrite and Add retain an existing unique index spelling
rather than adding a canonical peer. Case-insensitive volumes also check case
aliases; canonical spelling aliases remain guarded on all volumes. Git ls-files,
mv and add disable argument precomposition for those resolved exact paths.
Normalization-only rename remains available for a unique source and updates the
index name while preserving separate staged/working bytes. Destination inode
checks distinguish an alias of that source from an occupied different file.

Recursive copy preflight now uses an exact-keyed fingerprint map; ignored copied
repository checks and staging exclusions use exact paths/component prefixes.
Captured copy targets are compared exactly again before replacement. Move and
Rename window cache keys retain raw source identities, and workspace callbacks
remap only the exact moved path/subtree. The workspace overview's broader native
selection storage is not migrated by this continuation.

The source per-item failure/collision choices, captured destination, progress,
cancellation, partial-success policy and original icons remain in use. This is
a macOS filename-identity adaptation of the pinned DropMove/PasteMove/
DropCopyAdd/PasteCopy workflows, not a new transactional transfer engine.
See [transfer identity evidence](qa/file-transfer-identities-2026-10-17.json)
for the grouped checkpoint. Physical drag/panel/Finder acceptance, filesystem
ACL/xattr fidelity, race-free external mutation exclusion and signed sandbox
acceptance remain open.

Foundation file-URL construction was observed decomposing the composed spelling
before identity comparison. Transfer URL construction and Finder request decoding
now use URLComponents; lexical dot-component cleanup preserves raw path spelling.
Rename builds its entered target lexically, and Move resolves the destination
folder separately from the new leaf name. This prevents both accidental ancestor
renames and loss of an explicit normalization-only rename.

The current Debug build, 61 focused Core cases and all twelve native case/engine
combinations passed. The first Core checkpoint failed three assertions because
Foundation had already decomposed the original URL spelling; the correction and
added destination-folder regression are recorded alongside those failed results.
The native run retained all six families with system and bundled Git. All twelve
owned receiver PIDs were reaped and independently absent. No full Core suite was
rerun and no screenshot or full visual audit is added. Unsigned clipboard
sandbox-extension diagnostics do not prove signed permission delivery.

The connected [workspace file workflow continuation](WORKSPACE-FILE-WORKFLOWS.md) covers exact overview selection, Finder reopening, shared viewer caches and Add/Commit drop identities. Earlier workspace-selection limitations describe the prior checkpoint; complete physical/signed and application parity remain open.

The connected [source drop-command continuation](COMMAND-LINE.md#dropped-file-move-and-copyadd-entry)
adds automatic execution after captured destination adoption for explicit Move,
Move/Rename and Copy/Add commands. Existing native menu/clipboard reviews remain.
Owning preferences now reach the shared Move and Copy/Add consumers. Actual
validation and remaining acceptance are recorded in
[the command batch evidence](qa/transfer-commands-2026-10-18.json).
