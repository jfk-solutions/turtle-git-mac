# Commit, Add and Revert folder reads

This connected batch bounds Add/Revert discovery before Git reads and retains
that invocation boundary through refreshed Revert preflight and Retry. The
grouped checkpoint passed with retained Core/native scopes and focused repairs. This is one completed read/ownership family, not complete workflow or
whole-port certification.

## Source reference and semantics

Pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d` passes the original
selected path list to Add `GetStatus` (`AddDlg.cpp:148`) and Revert `GetStatus`
(`RevertDlg.cpp:117`). `GitStatusListCtrl.cpp:4136` delegates to
`GetWorkingTreeChanges` with the selected list and included-staged policy.
`Git.cpp:3460–3512` loops each selected path separately. Its cached raw query
uses that single path unless included-staged is enabled, in which case the
cached query is global; its whole-tree query stays on that single path.

These distinctions affect behavior, beyond speed. A rename into the selected
folder from outside it is Added when only the destination is in the query.
Later global fresh-status discovery must not turn that accepted Added row into
a Rename that restores or disposes an outside source. Combining separate
selected file pathspecs in the raw query can likewise introduce pairings that
were absent from each source query.

## Core interface

The status, source projection and working-tree report APIs accept
`paths: [String]? = nil` and `includedStaged: Bool = false`. Existing nil defaults
retain global consumers, including Commit. Explicit empty scope reads nothing;
`["."]` is the literal repository-root invocation. Empty names, absolute names,
NUL, traversal and administration paths fail before Git. Raw Git path identity,
input order and stable duplicate removal are retained. All commands use the
existing `--literal-pathspecs` invocation and `--` separator; names containing
wildcards, newlines or pathspec-looking punctuation remain names.

Scoped porcelain reads loop each selected literal path independently and parse
the concatenated NUL packets with stable first identity. This keeps destination
Added and old-name Deleted as two actual rows when those are separate
invocations, rather than losing the old name through a combined rename query.
Clean/index-flag inventory receives only the selected literal pathspecs. Source
cached/whole reads loop those paths independently in caller order, preserving exact C-before-M options, cached/default-50 versus
whole/configured threshold, first origin, old-name alias and exact-R later A/D
suppression. Included-staged widens the cached raw query and publishes independent outside
staged rows too. A global cached `diff --name-only --no-renames` index roster
finds missing names; argument-budgeted status reads for only those names use
`--untracked-files=no`. Existing selected-scope XY wins, and raw cached
first-origin/alias rules still apply. Outside accepted staged rows receive exact
assume/skip index flags through the bounded `commitDisplayIndex` query, while
selected-folder clean inventory remains scoped. Untracked/ignored traversal never becomes
global; ordinary Add/Revert pass included-staged false.

Add uses its original scope before status discovery, then applies its existing
unversioned/ignored/direct-file filters. Clean direct files retain their real
index metadata without a second repository-wide working-tree report. Revert
submodule mode metadata uses only its accepted row names through the optional
scoped submodulePaths/submodulePathNames API, with argument-budgeted literal
ls-files queries; nil retains independent global callers. Scoped
`workingTreeFiles` and `stagingFiles` bound all three name/statistic/raw reads;
`workingTreeStatus` bounds clean-file flag enumeration as well as changed rows.

`workingFileRevertSelection` and `revertWorkingFiles` accept the same optional
scope. The caller must capture the original invocation and pass that immutable
value through refresh, acceptance, fresh mutation validation and Retry. They
reuse scoped parent/amend status, supplement ignored metadata only for missing
exact requested names, and retain existing counterpart/clean/absent-item rules.
Explicit scoped Revert requests reject any destination or Rename-only old-name
counterpart outside the original boundary, including an empty scope, before
launching Git; missing-name supplementation cannot reacquire it. Nil retains
legacy global behavior. Fresh validation still checks exact accepted status, raw paths, filesystem
ownership and cancellation before disposal/index publication. Source Added
never gains an outside origin from a later global read when the scope is kept.

Automatic observers and supplemental raw reads retain `GIT_OPTIONAL_LOCKS=0`;
diff/statistic reads also disable automatic index refresh. This does not change
explicit refresh-index semantics. The existing global raw tracked-name ownership
check for disposing a present unversioned/ignored filesystem projection is a
separate safety boundary: it prevents an alternate tracked spelling from sharing
that entry. It enumerates the index, not unrelated untracked/generated trees.
Narrowing it by a literal parent could miss another raw spelling of that parent.

## Scoped Commit capture

Pinned CommitDlg.cpp:1404–1415 always enables included-staged and scopes
discovery unless Whole Project is selected. The captured Core read accepts the
same optional paths boundary; nil retains the existing global three diff scans
(two for an unborn repository).

The initial porcelain and whole-tree reads loop selected paths independently.
One global cached raw/numstat stream supplies both accepted source reporting and
the staged roster; missing outside names receive bounded exact-path actual XY
reads with untracked discovery disabled. No second cached-name diff is needed.
Parent-amend compares that global cached inventory to the actual parent, keeping
outside HEAD-only changes even when current HEAD status is clean. The Classic
working report uses cached statistics for accepted outside staged rows absent
from its scoped whole read; inside whole statistics keep precedence.

Unstaged reads cover the original scopes plus argument-budgeted exact outside
staged destination/origin names. This retains an outside MM row's actual partial
staging and unstaged numbers without admitting outside unstaged-only or
untracked trees. Source reporting reuses captured cached/whole bytes; flags come
from exact accepted-row index queries. Explicit empty scope launches no diff
inventory queries. Whole Project uses nil.

## Regression boundary

`ScopedWorkingStatusTests` prepares literal wildcard/Unicode/control-character
paths, unrelated untracked/generated trees, scoped clean and ignored/direct
rows, and a real rename from outside the invocation. An argv wrapper records
actual status/raw/index/statistic query boundaries. Separate cases check raw
per-path porcelain/raw loop ordering, included-staged outside Added/Modified
row visibility without outside untracked traversal, no-Git rejection of empty
or outside Revert requests/counterparts, index byte
preservation, empty scope, cancellation and rejected traversal.

The Revert case requires an actual globally detected Rename to stay Added under
the selected-folder scope, remain Added during fresh selection, leave the
outside index/worktree untouched during mutation, and remain local during Retry.
A paired independent destination/old-name invocation must retain both A/D rows
and Revert both, restoring the old bytes while keeping the added working bytes.
These are written assertions awaiting the grouped Core/native checkpoint.
Physical Finder integration and all historical/amend combinations are not proven
by these cases.

Commit regression cases assert scoped untracked visibility, outside staged MM
actual XY, separate staged/unstaged numbers, Classic cached-statistics fallback,
no duplicate cached-name roster, global cached query count, Whole Project,
parent-amend outside HEAD-only changes and literal multi-path source aliasing.
Existing global captured-read command-count assertions remain unchanged.

The first grouped native run exposed an additional global Revert submodule-mode
inventory. The repaired consumer passes its accepted literal row names, and a
focused Core case prepares real inside/outside gitlinks to assert bounded mode
queries, directory recursion and unchanged nil/global discovery. This repair
awaits its affected checkpoint; earlier Commit/Add native results do not prove it.
