# Historical viewer identity and retirement

Implementation continuation, 2026-10-23. The grouped checkpoint passes after the recorded fixture repairs; this does not certify complete historical viewer or source-dialog parity.

The pinned TortoiseGit source is `7338078f8ddd924b8cddee35f512f2286072136d`. `src/TortoiseProc/FileDiffDlg.cpp:412–435` selects the comparison's old path for replacements and empty-side roles for additions/deletions before invoking the diff tool. These inputs belong to the requested comparison, along with its destination, revision endpoints and alternate-tool choice.

`RevisionComparisonWindowModel` already uses `GitPathMap` for both comparison and Unified Diff children. Its parent reuse predicate already compares scope paths and revision labels with exact UTF-8 identity. The raw composite key and those predicates did not need another encoding layer to distinguish canonical-equivalent Git spellings. Core historical file lookup also already compares raw Git path identity; this continuation does not change comparison-file materialization.

The comparison-child key now also captures the optional rename-source path, including its presence, and the file action. A refreshed or embedded list can therefore request another preimage or added/deleted role for the same destination and revision endpoints without receiving a child that still owns the earlier snapshot. Existing preference ownership and alternate-tool selection remain part of the presentation path.

A child whose native owner has retired remains retained until its pending close work drains. A new Compare request opens a fresh owner instead of reopening the retired child; the retired owner moves to a separate collection until its real close callback settles. Parent reuse and close ownership include those retiring children. The eventual close callback removes the active cached value only if that value is still the same controller, preserving the replacement owner. Active and dirty child behavior is otherwise unchanged.

The grouped checkpoint targets actual windows with independently authored canonical-equivalent Git names, repeated request reuse, changed rename metadata, retirement, and late close callbacks. Core content identity, physical Finder integration, signing, and complete dialog parity are separate claims.

The workspace Log, repository Browser and Changed Files parent registries now use
`GitPathMap`, preserving UTF-8 spelling rather than Swift String canonical
equivalence. Log scope keys sort by UTF-8 bytes; scope setters and range reuse
compare exact paths and endpoints. Browser reuse checks both its requested and
loaded revision. Quit, dirty-child and pending-operation gates remain active.
The existing exact comparison-child registries are retained rather than counted
as new Unicode fixes.

Raw window identity alone cannot guarantee the displayed contents: macOS Git can
precompose command arguments when a repository enables `core.precomposeunicode`.
Readonly history walks, scope-kind lookup and initial named Browser resolution
therefore set `-c core.precomposeunicode=false` on those commands. This preserves
the requested spelling without changing repository configuration, HEAD or index.
Core coverage authors objects and packed references directly so two different
Git spellings do not depend on the host filesystem accepting both filenames.

The workspace comparison receipt also includes file action alongside the already
captured optional old path, endpoints and alternate-tool selection. Its retired
native owners already retain themselves through pending work; exact repeat
requests now create fresh replacements and identity-guard late close removal.

This continuation applies to the `IDD_LOGMESSAGE`, `IDD_REPOSITORY_BROWSER` and
`IDD_DIFFFILES` workflow families. Their resource mappings remain partial; exact
request identity does not certify the remaining controls or source layouts.
The [dated evidence](qa/historical-window-identity-2026-10-23.json) records actual
validation attempts and remaining acceptance.

The grouped checkpoint passes 13 relevant Core methods and eight distinct native
case/engine pairs (Compare, Changed Files, Log and Browser with system and bundled
Git). The Debug app build exited zero with nine generic “failed with exit code 0”
diagnostics. Native validation exposed two fixture setup errors: constructing raw
packed refs through normalized loose files, and attempting to dirty an immutable
historical pane. Direct raw packed-reference authoring and a real editable working
child repair those setups without removing the corresponding assertions. Ten
receiver attempts were reaped and independently confirmed absent. Passing Core
checks and the app build were not repeated for these fixture-only changes.
Physical interaction, VoiceOver, installed signed grants, minimum-version/Intel
acceptance and a complete current hosted integration pass remain separate gates.
