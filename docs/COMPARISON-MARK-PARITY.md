# Comparison marks: app and Finder

This is an in-progress source port, not a claim of complete DiffLater parity.
The native historical Log mark/compare route is recorded separately in
[Log parity](LOG-PARITY.md). Finder's shared working-file command route is implemented; signed Finder
activation and end-to-end menu acceptance remain pending.

## Upstream behavior

Audited pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`:

- `src/TortoiseShell/ContextMenu.cpp:590–604` changes DiffLater's label to
  Compare with and compacts the saved absolute path.
- `ContextMenu.cpp:1350–1371` sets a mark on the first single-file invocation,
  invokes file Diff with the current and saved paths on the next invocation,
  then removes the external mark. Control clears it; Shift requests an
  alternative comparison tool.
- `src/Git/GitStatusListCtrl.cpp:3170–3179` imports a changed external mark as a
  working-copy path, including marks outside the current repository.
- `GitStatusListCtrl.cpp:2155–2166` keeps a dialog-local historical mark after
  comparison, but consumes an external mark if that saved path is the one used.

Windows registry state must become app-private bookmark storage plus a shared
menu record on macOS. A Finder URL is a selection request, not a permission.

## Implemented storage and access foundation

`WorkingComparisonMarkStore` in `RepositoryAccess.swift` persists one file mark
and its authorization bookmark in the containing app's private support folder.
The bookmark may grant that file or a containing folder. Relative paths allow
folder bookmarks to renew after a move. Every operation reloads the private
record; consumption compares the mark's unique ID, so an old comparison cannot
consume a replacement mark, even at the same path. Missing files and unavailable
permissions fail without clearing the saved mark. The acquired access object
retains its scope lease until the comparison releases it. Corrupt records fail
visibly. File/directory permissions are 0600/0700.

`WorkingComparisonMarkSnapshot` in `FinderCache.swift` publishes only an ID and
absolute path, never a bookmark, into the entitled app-group container. Its
reader validates the path. An unsigned process without that entitlement gets
no implicit shared-container access. Tests use explicit disposable paths.
Neither the private store nor shared snapshot launches Git or changes file bytes.
The preview app's private storage remains isolated by its bundle identifier.

Thirteen repository/mark access tests pass. The four new mark tests cover
relaunch, literal Unicode/newline paths and binary bytes, metadata-only sharing,
permissions, scope lifetime, moved file and folder bookmarks, access failures, deleted
files, replacement/consumption, directory and escaping-link rejection, and
corrupt storage. These use an injected bookmark provider; they do not establish
signed macOS permission behavior. Debug and unsigned App Store builds pass. Bundle audits verify the embedded
Finder extension, 64 original icon resources, and 11 universal Git runtime
Mach-O files with local Git operations. Signed runtime acceptance remains
pending. No QA app was launched for this storage-only change.

## Working-file command route (2026-10-05)

Finder now offers a single-file mark/compare action with original comparison
artwork. Its label reads the shared metadata record; Control invokes clearing.
The app exposes the dynamic action and explicit Clear comparison mark command
in its TurtleGit menu, and the working file table offers the same action for a
single selection. With no selection, the app uses a native file chooser.
The request handler routes these commands before repository discovery, so both
files can belong to different repositories or lie outside repositories.

The app reuses saved repository access or requests the current file/containing
folder in the App Store configuration. It reacquires the marked bookmark and
retains both leases in the comparison window. WorkingFileComparison reads exact
regular-file bytes or literal symlink target text and rejects directories. The
existing viewer supplies Reload, explicit editing, Save/Save As and diff tools.
Both standalone and repository saves now share the existing byte/mode validation,
encoding preservation and temporary-file replacement helper. Git metadata is
not touched by standalone comparison or Save. Only the consumed mark ID clears;
failed authorization or reads leave the mark available.

Twenty-nine focused comparison, mark-access and Finder-request tests pass,
including two new standalone tests for literal paths in separate locations,
UTF-16/BOM and executable permissions, saving either side, unchanged Git index
and HEAD, binary/symlink reading, stale bytes/modes, foreign documents and invalid
locations. New mark/clear URL round-trip coverage confirms that these actions do
not produce Git command arguments. Debug and unsigned App Store builds and
both icon/runtime audits pass. The preceding storage commit's macOS and Pages
runs passed; this change's CI requires a separate check after push.

## Native acceptance and limits

An ad-hoc Debug preview received a single-file mark request after opening a
known disposable repository. The main window reported the marked path and the
native TurtleGit menu showed Compare with that path plus Clear comparison mark.
Menu activation attempts returned stale accessibility IDs; no successful direct
menu chooser handoff is claimed. The app quit normally with the mark persisted.
After verifying process absence, the same preview was configured with an outside
file request and deliberately relaunched. The native viewer compared the marked
14-byte `later working` with the outside file's 17-byte `external partner`.
Enable editing made the marked pane editable; toggling it off restored the
read-only view. No Save or file mutation occurred. The private mark was consumed,
the app quit normally, and exact HEAD/index/working/outside bytes and deleted-file
absence were verified. Only one QA process was alive at a time.

[Recorded evidence](qa/working-mark-2026-10-05.json) and the
[actual native screenshot](site/assets/working-mark-comparison.png) cover the
request route, persisted access, viewer contents and editing toggle. This is not
an activated Finder extension or signed sandbox acceptance test.

## Remaining parity and acceptance

- Import external marks in Log without treating absolute working paths as
  historical repository paths; retain dialog-local marks and consume only the
  external token actually used.
- Match compacted menu labels and Shift alternative-tool behavior.
- Verify native file-chooser cancellation, direct menu activation, explicit Clear,
  Control clearing from Finder, Reload, Save/Save As and external-change refusal.
- Verify different repositories, moved/missing files, symlinks/binary/encoded
  contents, Finder extension activation and signed sandbox permission behavior.

Full DiffLater, Log and Finder parity remain incomplete.
