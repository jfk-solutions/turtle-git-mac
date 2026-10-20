# Word and LibreOffice comparison handoffs

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`contrib/diff-scripts/diff-doc.js` and `merge-doc.js`.

## Connected source behavior

| Source behavior | Mac adaptation |
| --- | --- |
| `diff-doc.js` falls back to OpenOffice when creating Word fails | An unavailable Word installation selects the existing LibreOffice UNO adapter using fresh editable copies of the same captured bytes. Permission denial, compile failure and uncertain automation do not start another application. |
| Modern Word branch swaps inputs before its comparison | Captured base is opened and compared against captured new, preserving the existing modern direction, target-new, author and formatting options. |
| Outline/master/reading view normalization | Normalize outline unconditionally; normalize master/reading only when no subdocuments exist. The condition preserves source operator precedence. |
| Mark comparison result saved, then close source | Discover a unique new window and reject preexisting document names before marking its document saved; close only the captured private input. Ambiguous results remain available for review. |
| Suppress automatic macros | Disable and read back automation security before opening inputs, then restore and read back the previous setting on success and failure. Failure to confirm restoration fails the handoff. |
| Modern three-way Word merge | Preserve base/theirs and base/mine tracked comparisons, then merge theirs into private mine. Close captured base/theirs on failure; preserve a possible edited mine once revision editing starts. |
| Merge uses Word only | No automatic LibreOffice merge fallback. Its explicit adapter retains the source mine/theirs UNO workflow and existing Save As/Mark Resolved instructions. |

## Native ownership

Word and LibreOffice comparison requests keep captured access leases and Quit
accounting until their workers finish. Owner closure, task cancellation and app
cleanup cancel the captured token. Word receives a private marker and checks it
between commands; cancellation cannot undo a command already in flight. The
serialized handler still attempts input cleanup and security restoration before
returning a typed receipt. Macro-security failure, malformed completion or an
uncertain result retains private files. Proven unopened/retired requests remove
only their own preview directory.

Input closure uses the exact private full path. If a partial open loses its
returned reference, cleanup may reacquire only a unique exact private-path match
that was absent before dispatch. Unknown or ambiguous ownership retains files.
No cancellation path quits Word or closes its active document by selection.

The installed Word dictionary has no result value for `compare`. New-window and
preexisting-document exclusion is a conservative adaptation, not an atomic result
provenance guarantee during concurrent user-created/closed windows. That physical
acceptance case remains open; the port does not claim exact Word ownership solely
from a successful injected receipt.

## Validation boundaries

The grouped runner is `scripts/test-word-office-family.py`. It uses private
preferences, temporary repositories/files and hidden offscreen windows. The
existing dispatcher fixtures cover captured bytes, fallback selection, denied and
uncertain handoffs, Save As/explicit resolution, stale responses and worker/Quit
lifetime. The additional automation fixture runs the actual compile/event/typed
receipt bridge with injected replies, including malformed/security/cancellation
receipts and merge error mapping. Script-contract assertions inspect the fixed
ownership and view/security statements. They do not execute those statements in
Word. An optional dictionary check compiles both handlers without executing an
Office command.

Live Word output, macro behavior/restoration, concurrent window activity, Word
format converters, LibreOffice runtime compatibility, real TCC and file grants,
physical interaction, minimum OS and signed App Store acceptance remain open.
PowerPoint shape-level revision decisions and editable merged decks remain a
separate implementation gap. See the user guides for current workflows:
[Word comparison](WORD-COMPARISON.md), [Word merge](WORD-MERGE.md),
[LibreOffice](LIBREOFFICE-COMPARISON.md).

[Batch evidence](qa/word-office-family-2026-10-20.json) records the passing Debug
build and eight native case/engine combinations, compiled Word terminology,
owned receiver cleanup and remaining physical/signed limits. Core was unchanged.
