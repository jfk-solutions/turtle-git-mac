# Repository Browser Git filename handling

This is a partial workflow review against pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`, not certification of the whole Browser.
The reviewed dialog is `src/Resources/TortoiseProcENG.rc / IDD_REPOSITORY_BROWSER`.

## Source behavior and the missing native behavior

`src/TortoiseProc/RepositoryBrowser.cpp:368–425` enumerates tree entries, converts
each name with `CUnicodeUtils::GetUnicode`, and inserts it into a `CString` map.
`src/Utils/UnicodeUtils.cpp:228–241` uses `MultiByteToWideChar` with flags zero.
That source continues listing a directory containing a malformed UTF-8 name,
although replacement decoding loses the original bytes and can merge names.
The previous native strict UTF-8 parser instead rejected the entire listing,
making valid siblings unavailable too.

The native replacement preserves each Git path as bytes and each row as a
distinct identity. Ordinary UTF-8 paths retain their existing string keys;
unrepresentable paths use an internal NUL-prefixed key. Git cannot store a NUL
in a path, so that key cannot collide with a real filename. The key is never a
display label, Git argument, clipboard filename or filesystem destination.

Raw names display replacement text followed by their complete hexadecimal byte
sequence. A separate `[raw]` qualifier, tooltip and accessibility label distinguish
them from a valid filename that happens to contain the same visible text.
Copy displayed name explicitly copies that presentation; Copy hash retains the
exact stored object ID. This byte identity is a native extension beyond the
source's decoded map, required to avoid routing one displayed row to another.

## Connected navigation, inspection and transfer behavior

Raw directories remain navigable in the folder tree and contents list. Refresh,
expanded ancestors, selection identity and path presentation retain their byte
identity. Traversal matches raw component bytes in tree listings and passes
verified hexadecimal tree IDs to Git rather than reconstructing a lossy path.
The original pinned root tree and revision continue to own the snapshot.

View stored blob opens a parent-owned read-only inspector with the escaped path
and exact object ID. UTF-8 text displays as text; binary data displays as hex.
It reads stored bytes without smudge filters or a temporary filename and has an
explicit 8 MiB display bound. Closing the Browser closes its inspectors; cancelled
or retired reads cannot publish another window. Inspection neither edits the
working tree nor substitutes for the normal filtered Open/Save workflow.

Filesystem delivery, working comparison, marks, history/Blame, submodule checkout
resolution and Revert require a representable path. Their menus and underlying
dispatchers refuse raw names with an explanation. Double-clicking a raw directory
still navigates it; a raw file can be inspected through its stored object command.
Valid sibling files retain ordinary actions.

Selected folder transfers preflight the complete selected descendants. A raw
descendant refuses that folder delivery rather than skipping the item or naming
it after escaped text. Raw names elsewhere in the repository do not prevent a
valid sibling transfer. Export and promise callbacks retain their existing
private preparation, cancellation, exclusive destination writes and cleanup.

The parser still rejects malformed headers, duplicate raw records, traversal
components and inconsistent object modes. Ordinary nonstandard permission bits
are normalized by Git and the source's `git_tree_entry_filemode`; this review
does not invent a separate permission mode absent from either reader.

## Verification and remaining work

The [grouped checkpoint](qa/repository-browser-namespace-2026-10-25.json) records
33 focused Core methods with zero failures, a successful repaired Debug build,
eight native listing/navigation/actions/ownership case/engine pairs and six
existing selection-drag case/engine pairs. Both system and bundled Git passed.
The first Debug build caught a shadowed error-property assignment; that one-line
repair and the affected rebuild are retained in the evidence. The successful
build also emitted 35 generic command-failed-with-exit-zero diagnostics.

Native cases exercised actual table menus, stored-object bytes, light/dark
inheritance, child release, valid sibling promise delivery and held-read owner
retirement. They used private repositories, preferences, configuration and
pasteboards with invisible/offscreen windows. All 14 owned receivers were reaped;
the final process check found no remaining receiver or Debug app. No physical
screenshot was captured. Full Core and unrelated native families were not rerun.

Full raw-byte filesystem checkout, save, history routing and delivery remain
unimplemented. The explicit refusal keeps these operations from targeting a
replacement spelling. Physical gestures, VoiceOver, signed sandbox grants,
receiving-app delivery and complete upstream visual parity require separate
acceptance. This review supplies no whole-port completion percentage.
The installed signed application remains the earlier viewer-family candidate;
this Browser batch is verified in the local unsigned Debug build only.
