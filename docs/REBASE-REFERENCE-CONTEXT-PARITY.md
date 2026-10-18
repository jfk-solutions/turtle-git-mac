# Rebase embedded history reference context

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This is a partial workflow-family audit of `IDD_REBASE`, not completion of the
Rebase resource or the application. The native surface is `RebaseReplayTable`
and its `RebaseWindowModel`/`RebaseWindowController` owner.

## Source and implementation

- `src/TortoiseProc/RebaseDlg.cpp:286,327–336`: the embedded list suppresses
  ordinary HEAD font highlighting and removes Cherry Pick, Checkout revision,
  Reset, Revert, Merge, Rebase-to-version, Revert-to-version, Combine and Rollup
  from the shared menu mask. `ID_SWITCHBRANCH` remains permitted. Native controls
  keep that mask and additionally refuse mutation while a replay/owned child
  operation requires exclusive access.
- `src/TortoiseProc/GitLogListBase.cpp:1952–2082`: Show Log uses the shared
  reference-or-extended-menu exception; Browse, Switch Branch, Create Branch,
  Create Tag, Export and Notes retain source order. Switch excludes the current
  full local ref; a pointed badge restricts the candidates. Multiple local refs
  produce a submenu. Current ref/HEAD are read under the existing cancellable
  column/reference operation, not guessed from a replay plan's branch field.
- `GitLogListBase.cpp:2093–2132`: exactly two or a contiguous larger selection
  compares first/last displayed occurrences. Two occurrences expose both range
  directions, symmetric difference and `ID_COMPARETWOCOMMITCHANGES`. Native
  Compare dispatches actual occurrence endpoints, including repeated hashes.
- `GitLogListBase.cpp:2185–2226`: Patch precedes Push. Push is present for a
  local-branch/tag-associated revision, or Shift's extended menu, with a pointed
  local/tag caption and source icon. SVN DCommit shares that gate and requires
  Git SVN plus a working tree. Pull requires the displayed HEAD and no merge.
  Bisect Good/Bad/Skip/Start follow active/marked/merge/selection gates and the
  same existing shared command preparation as Log; these are not replay actions.
- `GitLogListBase.cpp:2241–2285`: Delete excludes the current ref, offers the
  pointed ref or a submenu and All. Rebase reuses `LogWindowModel.deleteReferences`
  and the Core reference-deletion snapshot, exact-object revalidation, remote
  choices, failure handling and cancellation. Its controller owns confirmation,
  failure and SSH sheets, inherits the parent's alpha, and resumes outstanding
  questions when forcibly retired. Busy/modal history actions block replay,
  editing, context menus, ordinary Close and Quit.
- `src/TortoiseProc/GitLogListAction.cpp:518–552,965–1007`: Export guesses the
  first tag. Create Branch honors any pointed canonical ref, otherwise guesses
  the first remote to retain tracking; Create Tag uses the first remote guess.
  Push prefers the pointed local/tag, otherwise the first local branch then tag
  then hash; peeled tag markers are removed, and explicit refs disable preserved
  All Branches. Existing shared native request/Push helpers supply these handoffs.
- Shared source `DrawTagBranch`/`DrawTrackingRoundRect` is represented by the
  existing `LogReferenceTextField`/`LogReferenceTextCell`: source palette roles,
  annotated tag tips, tracking links, symbolized names and optional labels on the
  right. Pointer hit testing and accessibility context actions use the actual
  clipped painter rectangles and full ref identity, never shortened label text.
  Rebase action backgrounds and current replay/Shift Find fonts are retained.
- Clipboard's Tag/branch names entry calls the shared exact source-name formatter:
  pointed names use the source short form, unpointed copies retain full refs and
  CRLF. All items retain source artwork and the inherited context-icon preference.

Each popup owns its exact occurrence selection, form generation and full ref map.
A native child/model state change invalidates the form generation, and a consumed
popup cannot run another item. A reference refresh replaces the menu context.
Repository refresh requests coalesce while an owned read, modal child or replay is
busy and do not replace the draft replay plan. Deletion completion requests the
same owned metadata refresh. Forced retirement cancels reads; global read and
mutation accounting remains owned until the underlying work drains.

## Grouped verification

The focused hidden receiver is
[`qa/rebase-reference-context-native-2026-10-18.swift`](qa/rebase-reference-context-native-2026-10-18.swift),
`RebaseReferenceContextVerification.verify()`. Arguments are an owned private
repository root and Git executable. It covers production painter geometry,
pointed context menus, annotated tag/source colors, canonical local/remote/tag
handoffs, Push persistence semantics, Switch current-branch exclusion, private
clipboard text, stale/one-shot receipts, source menu order and Bisect gates,
HEAD Pull, extended hash-only Push, contiguous Compare, real change-set viewer
preferences, repeated-occurrence change-set/Bisect dispatch, and actual hidden
Delete confirmation/refresh/Close/Quit ownership.
HEAD/index are compared before/after; owned windows close and reads drain on both
success and failure. Transport callbacks are injected to avoid external pushes,
pulls or desktop windows; the local deletion uses only the private test repo.

Retained `qa/rebase-history-tools-native-2026-10-18.swift` covers Find duplicate
occurrences/Shift highlight, history, ref failure sheets and cancellation drain,
Export, range logs and containing-reference helpers. Grouped results are recorded
in [`qa/history-reference-workflows-2026-10-18.json`](qa/history-reference-workflows-2026-10-18.json).
These new assertions have not been run by the implementation agent; the parent
owns the grouped checkpoint and the result record.

## Remaining boundaries

- Rebase supplies the selected occurrence count to the shared Log model for
  change-set/Bisect guards while preserving its ordered repeated entries. The
  ordinary Log default continues to use unique-hash selection. Equal-hash Bisect
  Start hands off the same source presets for review; it does not bypass Git's
  validation when the user later starts Bisect.
- No physical Finder, signing/deployment, remote push/delete server, Git SVN
  installation, or every-dialog visual acceptance is established by this fixture.
  Shared remote deletion and Bisect Git behavior retain their existing Core
  coverage; this receiver checks their Rebase placement/gating and ownership.
- Windows menus/flash cues, font metrics and shell rendering use macOS native
  equivalents. The retained Find status replaces Windows flashing/beeps.

Change-set comparison retains the source `hash~1..hash` command behavior, which
can reject root commits. The successful native comparison fixture uses two
parented commits and separately preserves repeated occurrences of one commit.
