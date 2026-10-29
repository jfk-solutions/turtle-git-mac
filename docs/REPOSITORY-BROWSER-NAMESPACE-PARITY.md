# Repository Browser Git filename handling

This is a partial workflow review against pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`, not certification of the whole Browser.
The reviewed dialog is `src/Resources/TortoiseProcENG.rc / IDD_REPOSITORY_BROWSER`.

The [raw historical-file transfer continuation](RAW-HISTORICAL-FILE-TRANSFER-PARITY.md)
adds safe-named providers/promises for individual files, including files inside
raw-named directories. Literal folder transfer still preflights every descendant.
The separate archive command preserves original member names inside a container;
neither continuation enables raw working-tree paths or original-name checkout.

## Source behavior and native filename handling

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

The explicit **Open stored blob (unfiltered)**, **Open stored blob with…**,
**View stored blob with alternative editor**, and **Save stored blob (unfiltered)
to…** actions deliver the exact Git object bytes even when its Git filename is
not representable as UTF-8. These are deliberately unfiltered object actions:
they do not apply checkout/smudge filters or manufacture a replacement spelling
for the Git pathname. The proposed leaf is `Git-blob-<full-object-id>` with an
optional1–16-character ASCII alphanumeric extension taken from the original raw
leaf. The private Open preview additionally carries the existing short revision
suffix. Neither internal row keys nor escaped display names become destinations.

Open/Save reuse the Browser's owned application/save panels, private historical
previews, launch permissions and cancellation/Quit lifetime. Refresh, navigation,
retirement or a late chooser/read callback cannot publish under a stale tree
receipt. The saved filename is a suggested leaf: the user still chooses its
actual destination. Blob mode and exact bytes retain their existing typed
content ownership; a symlink blob is delivered as its stored bytes, not followed.

The [historical materialization continuation](RAW-HISTORY-PARITY.md#historical-comparison-and-file-delivery-continuation)
now connects ordinary file Open/Save and historical comparison marks for raw
names; its [grouped validation is pending](qa/raw-historical-materialization-2026-10-27.json).
Open/Save retain the selected backend's established filter policy and propose a
safe blob-OID leaf, while explicit stored-object commands remain unfiltered.
Two historical endpoints can compare exact source bytes; a working-tree endpoint,
submodule checkout resolution and Revert still require a representable path.
Their menus and underlying dispatchers refuse raw names with an explanation.
Double-clicking a raw directory still navigates it. Valid siblings retain their
ordinary actions.

The [historical filename continuation](RAW-HISTORY-PARITY.md) now connects raw
file/folder Show log and file Blame to exact Git byte arguments and the pinned
Browser revision. Rename origins, Blame Previous/history navigation and selected
backend metadata retain those identities. Native captions and clipboard paths
use escaped labels; filesystem commands retain their explicit restrictions.
The continuation has its own [checkpoint](qa/raw-history-family-2026-10-27.json),
separate from the earlier namespace and stored-blob delivery results below.

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

The stored-blob delivery extension has a [separate grouped checkpoint](qa/repository-browser-stored-file-2026-10-27.json): 12 focused Core methods passed
after a fixture-only filter repair, and eight native listing/actions/ownership/
delivery case/engine pairs passed after a native compile repair. All eight
owned receivers were reaped and independently confirmed absent. The older results
above establish the original namespace/inspection batch only.
The new native delivery case covers invalid-name binary Save and its safe leaf,
actual private preview preparation with an injected document launch, the distinct
alternative-editor action, selected Open With success in a new private preview,
duplicate Save/chooser completion suppression, Open With cancellation/late retirement, retained menu
receipts, held read refresh/close/Quit gates, and unchanged repository state.
It uses the existing private receiver and invisible-window ownership policy.
No physical receiving application or signed-sandbox acceptance is implied.

Original-path checkout, working comparison and folder promise delivery for raw
names remain refused. A replacement spelling could address another file. A
[private filesystem probe](qa/raw-host-filename-2026-10-28.json) on the development Mac rejected creation of a name
containing byte FF with EILSEQ; this confirms a host-volume restriction in that
observed environment, not support or failure on every filesystem. Git tree
objects can still contain those bytes. Renaming them silently is not a faithful
checkout. Other filesystem profiles and raw folder delivery remain unverified.

Single historical file materialization, comparison and output under safe chosen
names have a [separate successful grouped checkpoint](qa/raw-historical-materialization-2026-10-27.json):
154 distinct Core methods cumulatively and seven native Browser cases with both
system and bundled Git. The earlier namespace/stored-blob checks above are not
its evidence. See [historical filename workflows](RAW-HISTORY-PARITY.md#materializationcomparison-checkpoint)
for filters, external-tool boundaries and original fixture repairs.
Physical gestures, VoiceOver, signed sandbox grants, receiving-app delivery and
complete upstream visual parity require separate acceptance. Earlier signed
installation receipts do not validate this continuation. This review supplies no
whole-port completion percentage.
