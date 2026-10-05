# Comparison marks: app and Finder

This is an in-progress source port, not a claim of complete DiffLater parity.
The native historical Log mark/compare route is recorded separately in
[Log parity](LOG-PARITY.md). Finder's shared working-file route is not wired yet.

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

## Required integration and acceptance

- Route Finder's mark/compare action to the app before repository discovery,
  allowing two files from different repositories or outside repositories.
- Publish changes and clearing to Finder, with original comparison artwork,
  dynamic compacted labels, Control clear and Shift alternative tools.
- Reuse or request access for the current selection; reacquire the marked file's
  bookmark and retain both leases through reads, reloads and any explicit edits.
- Hand both exact working-file contents to the native comparison viewer; preserve
  explicit editing, Save/Save As, encoding and external-change checks.
- Import external marks in Log, without treating an absolute working path as a
  historical repository path. Preserve dialog-local marks and consume only the
  external token actually used.
- Verify ordinary native marking/comparison/clearing and application relaunch,
  different repositories, moved/missing files, cancellation, alternative tools,
  symlinks/binary/encoded contents, unchanged indexes and signed sandbox behavior.

No native shared-mark screenshot or Finder end-to-end acceptance is claimed.
