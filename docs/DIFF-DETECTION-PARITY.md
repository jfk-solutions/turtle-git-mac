# Rename and copy detection family

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`,
`Git.cpp::CalculateDiffSimilarityIndexThreshold`, `GetLogCmd`, `GetCommitDiffList`
and `GitRevLoglist.cpp::GetFiles`.

The source percentage is shared by rename and copy detection. Its default is 50;
0 through 100 are accepted and values outside that range fall back to 50. The
Advanced Settings DWORD now affects repository sessions. Each session captures
an immutable detection policy, so paired status/name/statistic/patch reads do
not change rules while an operation is suspended. Existing sessions retain their
captured value; opening a new repository session reads the applied preference.

Working Tree status uses the explicit rename percentage. Commit/Working Tree
file statistics, stage/unstage lists, aggregate unified patches and staging
previews use the corresponding CLI rename/copy flags. Revision comparison now
detects copies by default, as GetCommitDiffList does; an explicit API choice can
still disable copies. Copy patches retain the existing whole-file-only staging
gate rather than allowing a partial copy header to change index semantics. Commit
uses the diff-statistics source path when porcelain lacks a copy originalPath,
so its selected-copy preview retains the header that enforces this gate.

Revision snapshots retain their detection policy alongside their pinned revisions,
options and scope. Generating a snapshot's patch through another repository
session still uses its captured policy. Selected-file snapshots preserve both
that policy and their original scope. Working history, followed rename walks,
batched revision actions, historical file lists and selected/root/preview patch
routes now specify their own policy instead of depending on Git defaults.

The two pinned backends differ at zero: CLI calls still emit `-C0%`/`-M0%`, while
GetFiles' libgit2 path skips find-similar entirely. The native historical file-list,
batched action and historical patch routes use `--no-renames` at zero to keep
those classifications aligned. CLI comparisons keep the literal source percent
flags. This distinction is deliberate; zero is not claimed to disable every CLI
comparison route.

Historical file-cache validation includes the exact detection policy and a
policy format marker. A cached low-threshold rename/copy record cannot be reused
as a strict or zero-threshold record for the same immutable commit. Existing
config, attribute, index, engine and environment fingerprints remain in effect.
No remote operation or repository configuration write is added by these reads.

Debug builds passed. The initial 113-test Core group found five assertions across
two failing test cases; a 15-test affected recheck passed after the flag-order
repair and fixture corrections. All 113 now have cumulative passing evidence,
without repeating the full group. Four initial native cases and two affected
copy-preview rechecks passed across system and bundled Git; all six receivers
were reaped. See [actual results and repairs](qa/diff-detection-2026-10-14.json). Full native
visual/pointer acceptance, all source copy candidate edge cases, configured
external tools, signed sandbox/Finder behavior and complete application parity
remain open. This family does not certify every diff or history dialog.
