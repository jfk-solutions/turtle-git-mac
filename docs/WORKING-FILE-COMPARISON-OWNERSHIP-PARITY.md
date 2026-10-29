# Working-file comparison intent and owner

Pinned `src/Git/GitStatusListCtrl.cpp` distinguishes explicit Compare
(`IDGITLC_COMPARE`, line 2234, through `StartDiff`) from the default activation
of a conflicted file (`OnNMDblclk`, lines 2926–2974, through ConflictEdit).
`CGitDiff::Diff` and `Commands/DiffCommand.cpp` implement explicit two-way
comparison. The native shared working-file route previously consulted the main
workspace's status rows, which could turn an explicit Compare into conflict
editing or use another repository's same-named row to choose the action.

## Requesting repository and explicit action

`showWorkingFiles` now always requests the selected repository's HEAD-to-working
comparison. Conflicted primary actions in Working Tree, Revert and Add route
explicitly to conflict editing; Commit and replay conflict actions retain their
existing explicit routes. Ordinary Add activation still previews its file.
Source file menus retain separate Compare and Resolve commands. The direct Add
scope can include tracked/conflicted rows, so it needs the same distinction.

Root-installed Working Tree callbacks validate the actual live controller before
routing either action. A retained Working Tree for a different repository keeps
that repository, permissions and preferences and does not adopt its root into the
workspace merely to edit a conflict. Explicit Resolve choices use the same root.

Working-file and working-pair reads capture the owning preferences, backend,
executable/askpass/rename policy, appearance, alternate-tool choice and paths.
Viewer cache identities now distinguish the Git/backend runtime as well as the
file/revisions/preferences, preventing a newer engine request from reusing an
older runtime's viewer. Existing Core empty-base/unborn, deletion, rename,
untracked, multi-file and submodule comparison capabilities remain in use.

## Read and question ownership

Working Tree, Add, Revert, Commit, Resolve and replay provide bounded captured-row
owner checks. Selection, refresh, changed rows, replacement, Quit or retirement
can cancel the pending session. Validation polls only the selected rows rather
than rebuilding a complete large-repository status map. Resolve/replay callbacks
can occur inside their own accepted request; that original busy interval and its
normal completion remain valid, while a different operation is rejected.

The comparison session owns its warning sheet. Its owner check deliberately
excludes that sheet's ordinary menu-unavailable gate, so presenting the warning
does not cancel itself. Cancellation ends its own question and cancels the actual
read token. Counters, access and repository ownership remain retained until the
real read returns, including a noncooperative injected reader. Late viewers and
errors cannot move to a new owner; active failures return to the requesting
model. Other historical comparison families retain their separate contracts.

The [grouped checkpoint](qa/file-comparison-browser-ownership-2026-10-29.json)
records actual build/native results and failed attempts. Implementation alone is
not a pass. Physical pointer/menu/keyboard delivery, real external tools, signed
sandbox grants, every historical caller and complete visual/source parity remain
separate acceptance scope.

The current grouped native checkpoint passes with system and bundled Git, plus
the affected Browser file-action, Add/Revert file-flow and replay/Resolve
regressions. The earlier fixture path-identity and synchronous cancellation
assumptions are retained in the receipt rather than counted as product passes.

A separate Core content-selection gap remains: `workingFileComparison` filters
unchanged explicitly selected files, although the pinned status-list StartDiff
normal-file route offers comparison. Amend/Added empty-base rules also require
their connected content-selection review. This native intent/ownership batch
preserves that existing Core behavior and does not certify those cases.
