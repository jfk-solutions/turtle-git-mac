# Clone checkout filters

Source pin: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`, with
libgit2 `f7164261c9bc0a7e0ebf767c584e5192810a8b24` (1.9.4).
This is a partial workflow-family port record, not complete application certification.

## Source contract and native scope

`Git.cpp:2493–2518` registers the custom filter driver globally, at
`GIT_FILTER_DRIVER_PRIORITY`. `CloneProgressCommand.cpp:35–108` configures the
normal libgit2 clone checkout with SAFE or NONE and therefore consumes that
registry. The source gate is Clone index1 / bit `0x2`, excluded by the default
`0x66780` mask. Ordinary default Clone remains the Git-command workflow.

The custom adapter follows `src/libgit2/filter-filter.c`: the configured
`filter.<driver>.smudge` command applies in checkout direction, `%f` names the
literal repository path, `%%` is a literal percent, optional failure passes
through and required/missing-command failures fail checkout. Its persistent
`filter.process` protocol and Git hooks are not part of that source adapter.
LFS support here means invoking a configured one-shot `git-lfs smudge` command;
it does not install filters, rewrite repository attributes or invent a server.

The native helper extends the already ported historical smudge adapter to the
initial Clone checkout and its existing recursive submodule option. Each filter
runs in its actual owning repository work directory, with captured configuration
and original Git/bin/exec-path environment. Inherited repository-location
overrides such as GIT_DIR/WORK_TREE/INDEX_FILE are removed from the filter child
so nested Git and LFS discover the actual owning checkout. Global and transient
configuration, credentials and executable search paths remain captured. That per-repository cwd is a macOS
adaptation: the Windows command runner inherits its launching ancestor, and
CloneProgressCommand itself does not recurse. The native recursive option was
already supported; this family makes its checkout filtering consistent.

Bare and no-checkout operations do not run worktree smudge filters. The pinned
libgit2 clone failure behavior removes a newly created destination or clears the
contents of a pre-existing empty destination. Failure during a later recursive
checkout happens after the superproject clone succeeded, so its completed work
remains. Neither cancellation nor recursive failure is reported as a rollback of
all completed clone work.

## Ownership and progress

The accepted Clone backend/options remain captured through destination/transport
preparation and native progress. Filter stdout supplies file bytes; diagnostics
and required-filter errors remain in owned progress output. Custom child process
groups use the existing separate filter-drain lock; cancellation publishes its
marker before interrupting the parent helper and waits for actual filter drain.
Prompt ownership remains independently locked, including nested Git tooling.
Close/Quit and result/post-action state follow the actual command lifetime.

## Evidence and remaining work

[Batch QA](qa/clone-checkout-filters-2026-10-19.json) records actual attempts and
source hashes at the grouped checkpoint. The completed grouped checkpoint below separates actual scope and repairs.
Core/helper/native checks use private repositories/configuration/output and actual filter processes,
including bundled Git LFS when available. Complete source parity cannot be
inferred from screen existence or a narrow passing corpus.

Persistent filter-process, working-tree-encoding behavior not provided by pinned
libgit2, arbitrary shell toolchains, broad external LFS providers and signed
sandbox filter/grant acceptance remain separate requirements. Full hosted CI,
physical UI/keyboard/VoiceOver and App Store distribution remain open.

## Explicit global configuration repair

The first grouped Core run exposed a production gap: pinned libgit2 repository
snapshots gate GIT_CONFIG_GLOBAL/SYSTEM behind repository `use_env`, which is
false for clone-created/opened repositories. The earlier open-default-config
adapter did not cover that separate repository loader. Tests using private
custom global filenames correctly showed skipped custom and LFS filters, while
-c-only helper probes had passed.

The private pinned patch now preserves captured config environment paths
in repository snapshots at their original levels, including includes/conditional
includes, explicit empty/missing paths and local/APP precedence. This must not
enable ambient GIT_DIR/worktree overrides for repository discovery. The grouped
repair record distinguishes this source fix from any fixture change.

## October 19 grouped result

19 distinct focused Core methods pass cumulatively: 15 in the initial group and
four affected methods after the production config repair. All four new methods
run, including actual bundled Git LFS with valid pointers/private cached objects;
no LFS skip is reported. The original 16 assertion failures across those four
methods remain recorded. Actual source/local/APP configuration precedence and
nonpersistent command overrides are asserted in the affected method.

The initial universal helper group passed its -c-configured cases but did not
prove global-file loading. The repaired private patch required rebuilding both
C-library slices under a new provenance cache key. Both-architecture validation
then passes explicit global/system files, includes, empty/missing suppression and
local/APP precedence plus all retained transport/historical/checkout checks.
Debug and its repaired helper republish pass. Packaged signed/unsigned mapping,
source hashes and pins match the prepared runtime; this is not distribution signing.

One native group passes with actual packaged Git/helper/LFS, private settings,
repositories/configuration/TMPDIR and pasteboard, and invisible windows/sheets.
It covers accepted choices, destination reply cancellation/duplicates/detach,
initial/recursive filtered bytes, suppressed checkout, source failure target
states and actual No/Yes/forced-close/Quit process drain. Receiver PID59857 and
its owned children are reaped; windows, sheets and workers settle. Only affected
Core methods were repeated after the config repair; the native group passed first
attempt. Full hosted CI, physical UI and signed deployment remain unverified.

Configured Git credential-helper fill/approve/reject is not a missing selected-
libgit2 source workflow: AppUtils.cpp:3701–3712 opens CUserPassword directly.
The native callback retains that boundary; ordinary Git continues to support
its own credential helpers. Persistent filter-process and ordinary Git hooks
likewise are separate engine boundaries, not newly claimed Clone behavior.
