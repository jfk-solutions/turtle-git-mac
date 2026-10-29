# Historical files with raw Git names: native transfer

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
The source contracts are `RepositoryBrowser.cpp` historical drag construction,
`GitDataObject.cpp` selected occurrences/GetOneFile delivery, and the shared
Log/FileDiff status-list drag consumers. Ordinary source filenames, selection
order, occurrence identity and checkout-filter behavior remain in place.

## Connected file delivery

Historical individual-file providers and promises now admit validated raw Git
namespace keys in Repository Browser and the shared Log/revision-comparison
file lists. The immutable request retains the accepted revision, exact path bytes,
selected backend and originating repository authority. No mutable branch, changed
selection, current workspace or working file is substituted during deferred load.
An already captured receiver-owned transfer can finish after its source closes.

At gesture time, a raw Git path proposes `Git-path-<SHA256 of exact path bytes>`
with an original ASCII alphanumeric extension of up to 16 characters when present.
This synchronous name requires no Git lookup. Different raw paths pointing at the
same blob retain separate names and items; repeated occurrences remain separate
items as in ordinary source transfers. Ordinary UTF-8 leaves retain their exact
spelling. The existing Open/Save blob-OID naming policy is unchanged.

Only the safe proposed leaf becomes a native temporary filename. Historical
materialization reads the original namespace key and applies the captured
GetOneFile backend/filter policy. Executables retain the established exported
mode; historical symlinks deliver their link text as regular files. A selected
helper/filter failure cannot silently switch to raw blob or working content.
Providers and promises agree on filename/type and actual materialization.

Raw clipboard text uses the existing byte-annotated display captions, never the
internal NUL-prefixed selection key. It is descriptive text, not a native path
or shell command. Source Browser Copy Names/Copy Hash remain text-only
(`RepositoryBrowser.cpp:876–889`). Aggregate Browser and shared file-list drag
pasteboard writers offer file promises alongside text; this is not a new keyboard
Copy Files command. An empty
comparison endpoint can supply text only, with no working URL or content fallback.

Repository leases, queued/active transfer receipts and prepared-file retention
survive actual callbacks and worker settlement. Promise publication uses the
existing coordinated exclusive writer: an existing receiver file is preserved,
and cancellation/failure discards owned staging and temporary files.

## Remaining boundaries

This is an explicit native filename adaptation. The delivered safe filename does
not recreate an unrepresentable original pathname. Use historical folder archive
export when the delivered container must preserve original Git member names.
Raw working-tree URLs, original-path checkout/mutation, raw submodule checkout
and literal folder promises with raw descendants remain restricted. Folder
transfers still preflight the complete inventory and do not omit raw descendants.
A valid sibling file remains independently transferable.

Physical drag/paste in external receiving applications, signed receiver grants,
minimum-OS/Intel execution, complete source acceptance and a current full hosted
pass remain separate gates.

## Grouped checkpoint

The [checkpoint receipt](qa/raw-historical-file-transfers-2026-10-29.json) records
19 focused Core methods and both native Git-engine runs passing on their first
attempts. Existing ordinary filenames, occurrence identity, working URL fences,
Open/Save naming and literal folder refusal are included alongside the new raw
file cases. The native fixture captures real Browser/Log/comparison consumers
through model selections and consumes actual providers/promises and private
pasteboards. It compares complete file bytes, names, types and modes; exercises
captured revision/backend and source-close delivery, independent lease retention,
exclusive output and actual held-process cancellation; and checks unchanged
HEAD, index, private configuration and working bytes. Both receivers are reaped.
This is private native delivery evidence, not a physical drag/keyboard Copy claim.
