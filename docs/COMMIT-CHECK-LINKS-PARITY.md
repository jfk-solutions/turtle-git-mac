# Commit category check links

Partial source review against TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`, dialog
`src/Resources/TortoiseProcENG.rc / IDD_COMMITDLG`.

## Source behavior and native gaps

`CommitDlg.cpp::OnCheck` (2504 onward) dispatches all nine Check links to
`CGitStatusListCtrl::Check`. Shift reverses checking; None reverses the result
again. `src/Git/GitStatusListCtrl.h` defines Added as added-or-copy and Modified
as the modification action bit. The control's action mask, not its human-readable
summary status, decides membership.

`GitStatusListCtrl.cpp::Check` (3287 onward) treats files and gitlinks separately.
DoNotAutoselectSubmodules prevents category checking of gitlinks unless the
requested mask includes SHOWSUBMODULES. SHOWEVERYTHING is all bits: therefore
All, Shift+None and explicit Submodules still include gitlinks. Unchecking does
not apply that exclusion. This source exception is intentional, even though the
preference caption alone may suggest a broader rule.

The previous native links selected through aggregate `StatusEntry.state` and
generic predicates. That lost copy membership in Added and conflated rename or
conflict display fallbacks with the raw modification bit. Bulk category selection
also lacked the source submodule policy. The native continuation shares action
classification across link availability and dispatch while retaining the source's
distinct counting rules. An enabled Modified link can still have no match for a
pure rename; source link counting and matching use different rules too.

## Connected workflow

Toolbar links and native menu routes use the same category selection policy,
captured file-list receipt, direction and submodule preference. Ordinary checkbox
mode changes checked paths. Staging mode sends the admitted paths through the
existing stage/unstage operations. Explicit row/group checking retains its own
selection semantics; the category preference is not a blanket ban on gitlinks.
Stale receipts and retired owners cannot mutate a newer listing.

The [grouped checkpoint](qa/commit-settings-source-parity-2026-10-25.json) records
13 focused Core methods and both affected bundled-Git filter cases passing, plus
eight Commit category and eight Settings handoff case/engine pairs. Core and
Settings passes were retained after the affected Commit-only routing rebuild.
The native checks found and repaired a real None command ambiguity: an optional
category return had interpreted `.none` as nil. Fixture parser/sheet compilation
repairs and Git-version diagnostic wording remain recorded too.

Both synthetic category cases still emitted AppKit's reentrant table-delegate
warning, including after exact native row readiness was added. Its origin is
unproven; it cannot be dismissed as fixture-only or described as fixed. Capture
the actual warning stack before changing list projection/selection ownership.
All owned receivers were reaped. No complete Commit, physical input, signed
application or hosted CI pass is claimed here.
