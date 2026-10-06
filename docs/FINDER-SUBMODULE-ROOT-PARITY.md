# Finder registered submodule roots

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
`TGitPath.cpp`'s `GetAdminDirMask` marks a working-tree root as a submodule when
`IsRegisteredSubmoduleOfParentProject` finds its relative path in the nearest
parent worktree's `.gitmodules`. An arbitrary nested repository is not enough.

App-side `finderMetadata` now collects an optional `submoduleParentRoot` by
querying the nearest parent worktree and matching `.gitmodules` path values.
Literal Unicode/newline paths and subsection names use separate NUL-delimited
config name/value queries. Includes are disabled. This matches registration
rather than using presence of any parent gitlink alone. Missing/inaccessible
parent metadata leaves the optional fact absent. Existing five-boolean metadata
records decode without it; new records retain the original fields.

The extension uses this cached fact only at a directory equal to its cached
worktree root. The flag supplies the existing source Rename/Remove alternatives;
Remove (keep local) remains hidden by the root exclusion. Ordinary repository
roots remain excluded. Cached rename/removal eligibility admits the registered
root while retaining versioned-status guards. Finder executes no Git commands.

The app's selection-root resolver now routes root Rename/Remove to the parent
only after rechecking `.gitmodules` registration and an indexed gitlink. Ordinary
nested repositories stay their own root; Log continues to use the child root.
Existing rename and removal backends then operate on the parent's relative
submodule path. Cached parent metadata also extends permission targets for these
Finder actions, so an existing child-only grant does not suffice: the app reuses
a containing parent grant or opens its repository authorization picker there.
The cache is only a picker/access hint; session adoption still revalidates the
actual selection root and lease containment.

## Verification and remaining work

Three new core tests cover old/new metadata, root flags/eligibility, a real
Unicode/newline registered submodule, parent routing for Rename/Remove, child
routing for Log, Git mv registration/index changes and Git rm removal with
unchanged parent HEAD. An ordinary nested repository and a similarly named
nonmatching config path remain unregistered. The focused regression passes
37 tests, including existing conflict resolution, rename/removal, submodule
update, repository metadata and path-condition coverage. The final full core
regression passes 481 tests with zero failures; Debug and unsigned AppStore
builds, both bundle audits and site generation pass.

The actual extension-source receiver verifies registered-root Rename/Remove are
enabled, hold the captured root and follow source order; RemoveKeep stays hidden;
ordinary roots exclude Rename/Remove. No Finder controller/extension/window is
activated. App parent-picker routing is compiled/source-audited, not native
picker or signed-scope acceptance.

Only refreshed child roots have this metadata. Collecting all submodule roots
and child statuses while refreshing a parent, uninitialized/removed/conflicted
registration cases, symlink/nonregular `.gitmodules` equivalence, multiple-root
selections, background monitoring and fresh signed handoff remain pending. A
child-only sandbox grant can prevent parent metadata discovery; the flag remains
unavailable until suitable parent access and a refresh. An older/missing cache
can still produce a root-outside-permission error during action discovery rather
than the cached parent picker hint. Full submodule and Finder parity is incomplete.

Build and regression evidence is recorded in
[the verification record](qa/finder-submodule-root-2026-10-06.json).
