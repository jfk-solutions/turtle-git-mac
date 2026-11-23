# Log working-row comparison operands

Baseline: pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`; native source base `bf00edd5`.
Status: connected implementation and grouped native checkpoint passed. Its
bounded evidence and remaining acceptance are recorded below.

## Source boundary and concrete difference

Pinned `src/TortoiseProc/LogDlg.cpp:1024–1032` assigns the selected commit hash to
the changed-file list's `m_CurrentVersion`. The working row has an empty hash.
Consequently `src/Git/GitStatusListCtrl.cpp:3026–3060` applies working-status
`StartDiff` semantics only to that sentinel: Added/initial uses an empty old
operand, Deleted uses a historical old operand and empty destination, and
Renamed/Copied uses the accepted `GetGitOldPathString()`.

Before this batch, native Log accepted those working rows but passed their path
and a common base to generic `revisionFileComparison`. That API redetects action
and rename/copy pairing from its later operands. Explicit Compare also used the
generic revision callbacks. The accepted raw status and original path were
available in `workingStatusEntry` but were not carried into Root preparation.
This source-supported handoff difference is exercised by the passing native
operand and rename witnesses below.

## Implemented accepted working-row handoff

`LogFilePrimaryAction.statusComparison(file:intent:)` carries the original
displayed `CommitFile` and an immutable `StatusListFileComparisonIntent`. The
intent retains the accepted raw `StatusEntry`, literal destination/original
path, submodule classification and pinned comparison base. Root calls the
dedicated `GitRepository.statusListFileComparison(_:cancellation:)` builder,
checks exact row/path identity, and checks its session/current-owner receipt
again before presentation. The builder does not rerun rename/copy pairing.

The base is the accepted working sentinel's captured parent: the synthetic
row's parent is HEAD itself, **not HEAD's first parent**. An initial repository
uses `.emptyTree`. There is no Log amend toggle to apply to this branch.
Added retains an empty old side; Deleted retains an empty new side even after a
disk leaf reappears; required ordinary/rename/copy old operands do not silently
become Added when absent. Raw unmerged porcelain pairs remain ordinary tracked
comparisons for explicit Compare, rather than inferring Added/Deleted action
flags from stage occupancy. See
[accepted status operands](STATUS-COMPARISON-OPERANDS-PARITY.md).

Default Return/double-click and explicit Compare remain distinct. Primary
activation edits conflicts, previews unversioned/ignored files and retained
unversioned copies as current working files, and skips source-ineligible missing
rows. Explicit working-sentinel Compare calls the same typed activation session
with `.compareWithBase`; it retains the accepted status action instead of
substituting the primary editor/current-file adaptation. Existing symlink
link-target text and submodule pointer/null-side adapters remain in use.

The existing native menu is retained, including icons, captions, mark and
inspection receipt. Native selection order determines ordered preparation and
one selection-count warning. The source captures raw accepted statuses before
that warning and checks them, the sentinel base, selected-row/file generation,
window and navigation owner before/after asynchronous work. Tool preferences,
Shift/alternate choice, diff backend and access/appearance ownership are kept.
Selection/revision replacement, changed settings, cancelled warning, Close and
Quit must retire a pending handoff. Streamed history append continues to use the
existing accepted-file navigation receipt; it is not permission to adopt another
working snapshot.

## Historical and current-file branches stay separate

Pinned `StartDiff`'s nonempty `m_CurrentVersion` branch has independent root,
Added, Deleted, merge-parent and combined-diff rules. `StartDiffWC`
(`GitStatusListCtrl.cpp:2996–3024`) also clears Added/Deleted and old-path intent
before comparing a current path to the selected revision or parent.

This batch therefore leaves historical `.comparison(file,from:to:)` requests,
parent-index selection, historical-current-to-working and historical-parent-to-
working requests on their existing revision routes. It does not substitute a
shared working HEAD rule for historical files, two selected revisions, merge
parents or historical/current-file previews. `.workingFile` retains its
independent current-version operand: the working sentinel compares the accepted
working path with itself, including retained local copies outside the index.
No comparison stages files, resolves conflicts, commits or refreshes the index
as a side effect of deciding its accepted action.

## Prepared checkpoint and explicit limits

The new private receiver is
`docs/qa/log-working-comparison-operands-native-2026-11-23.swift`; the grouped
driver is `scripts/test-log-working-comparison-operands.py`. It reuses actual
Debug objects through the native receiver cache and the retained actual Log
selection/owner helpers. Four cohorts passed with system and bundled Git:

- `operands`: native selected Return and actual Compare menu/Root preparation;
  Added versus a competing fresh pairing, Deleted versus recreated disk bytes,
  explicit conflict versus primary behavior, current-file/retained-copy preview,
  accepted synthetic C origin, one warning, captured settings and Quit refusal.
- `rename`: actual accepted rename, literal Unicode destination and original
  path, then explicit comparison after fresh detection would change its action.
- `historical`: actual merge-parent primary requests and historical-current/
  parent-to-working callbacks stay on the historical route.
- `ownership`: held warning followed by revision replacement, changed backend,
  declined confirmation and source close, with owned workers drained.

The CLI does not naturally discover copied rows in ordinary status collection.
The C witness injects accepted metadata into the receiving typed Root plan while
using real tree/working bytes; it establishes no copy-discovery claim. Contrast
reads through generic comparison prove fixture pairing conditions, not a change
to that independent API. Capture/deployment is not part of these tests.

All repositories, configuration, preferences, geometry and pasteboards are
private. Windows are invisible/offscreen; external presentation is injected.
The driver preserves failure evidence and retires only exact owned helpers on
success, failure or timeout. The fixtures assert actual operands and repository
preservation rather than only inspecting enum names.

The passing historical subset does not verify every two-revision/combined-merge
branch, renamed-submodule equivalence or every symlink/gitlink native presentation.
Core operand coverage from the prior status family remains separate evidence;
those Core tests were not repeated for this native batch. Physical
keyboard/mouse acceptance, signed installation, Finder integration, hosted CI
success and whole-dialog/source parity are not claimed.

## Grouped checkpoint

The app build and this family's native cohorts passed with system and bundled
Git. The [combined record](qa/remaining-comparison-consumers-2026-11-23.json)
retains failed attempts, focused fixture/compile repairs, passed scopes and
cleanup evidence. Core source did not change, so its previous focused pass was
not repeated. Local native checks do not establish complete hosted, signed,
physical or whole-dialog parity.
