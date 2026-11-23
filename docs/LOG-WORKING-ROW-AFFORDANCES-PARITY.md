# Log working-row actions and accepted status metadata

This batch connects the native Log report's status captions, colors, menus and
primary file activation. It uses the pinned TortoiseGit source at
`7338078f8ddd924b8cddee35f512f2286072136d`. It does not certify the whole Log dialog.

`GitStatusListCtrl.cpp:1739` suppresses base/unified comparison for Missing
Added/Renamed/Copied aggregates, while plain Deleted|Missing and
Modified|Deleted|Missing remain comparable. `OnNMReturn:3618` asks once for the
original selected count, processes rows in displayed order and skips those
ineligible missing rows. Log now uses the shared raw-porcelain eligibility
helper for menu and handler admission and filters its owned primary action plan.
The warning count, captured backend/settings/access/window and cancellation
owner remain the original accepted selection, including skipped rows.

`StartDiffWC:2996` clears Added/Deleted comparison intent and uses
`m_CurrentVersion`. For a working Log row that is the working-tree sentinel;
untracked and retained local files therefore prepare the explicit working file
on both sides. The Log action carries this source intent to Root instead of
silently substituting HEAD. Normal changed/deleted rows keep the accepted base
comparison; historical deleted rows keep their historical parent comparison.

The native report consumes accepted `workingIndexFiles` metadata. A literal-path
map is rebuilt only when an accepted status snapshot replaces that array; row,
color and menu lookups are constant time and perform no filesystem stat.
Captions follow `TGitPath.cpp:1782` (Conflict, Added, Missing, Deleted), while
colors independently follow `GitStatusListCtrl.cpp:3423` (gray, Conflict,
Modified, Added/Copy, Deleted/Missing, Renamed). Thus AD remains Added with the
Added color, MD is Missing with Modified color, and RD is Missing with the
Deleted/Missing color. Selection/gray and historical colors retain precedence.

A worktree-missing leaf cannot Open, Save As, Export, Reveal or become a working
comparison mark. A retained local copy after index deletion is different: the
macOS report keeps one Deleted row with `hasUnversionedCopy`, and physical
content actions remain usable. Base/unified comparison remains suppressed for
that local-copy row, matching its unversioned primary intent. This is an explicit
one-path-identity adaptation; it does not claim separate upstream rows.
Actual content operations retain their asynchronous fresh leaf/access checks.

The native receiver in
`qa/log-working-row-affordances-native-2026-11-23.swift` mounts real private Git
AD/RD/Deleted/Missing/retained-copy/untracked/modified states, inspects native
menus/icons, exercises accepted local reads and mixed Return through Root, and
checks stale menu/question retirement and historical D. CD's shared raw status
rule is checked directly because Git status need not discover copied files.
The combined native cohort passed with system and bundled Git. Save/Export
callbacks assert the accepted paths; Open validates the actual private working
leaf, and child viewer presentations are injected. See
[the checkpoint record](qa/status-activation-family-2026-11-23.json) for the
Core/app scope, fixture repairs and cleanup evidence.

Remaining scope: no new multi-commit file-list or untracked-directory parity,
no separate index-deletion/unversioned rows, no physical Finder/signed grant or
external-editor acceptance, and no complete visual/dialog certification.
