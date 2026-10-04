# Resolve parity

Baseline: upstream `7338078f8ddd924b8cddee35f512f2286072136d`, ResolveDlg,
ResolveCommand, IDD_RESOLVE and shared status-list resolution actions.

## Native dialog and operations

The checked conflict list includes Path, Extension and Status, followed by the
three-state Select/deselect all checkbox, commit reminder and OK/Cancel/Help.
All six resource controls have native mappings. Highlight selection and checked
selection are independent. Mixed and checked select-all clear the checks; unchecked
select-all checks every row. Frame position is saved and F5 refreshes the list.
The original menuresolve.ico is bundled with source/hash provenance.

OK stages only checked paths using their current working contents. Context menus
also offer Resolved, Resolve using mine and Resolve using theirs. Context actions
ask Yes/No before execution; normal OK follows the upstream checked-list flow.
Success reports the resolved count and offers Commit. No operation automatically
commits or continues a merge, rebase or cherry-pick.

Mine uses actual index stage 2 and theirs uses stage 3. During rebase the menu
labels explain these as the branch being rebased onto and commit being replayed.
A missing selected stage means deletion. Text, binary and symbolic-link sides use
Git checkout-index followed by add; current contents use add -f. Captured stages
are validated for every checked item before mutation. Literal path arguments
support leading dashes, Unicode and newlines. Paths cannot enter Git administrative
directories, escape the working tree through parent links or enter nested repos.
Later per-item Git errors can leave earlier resolutions applied; batches are not
transactional. Errors refresh parent models and retain the normal dialog.

Gitlink sides can update the index when their existing checkout matches the chosen
commit, or the submodule is uninitialized. A differing initialized checkout is
handled through the native Reset window, after which resolution revalidates and
resumes. Exact side pointers and mismatch rejection have dedicated tests; a native
Soft-reset/resolution handoff preserved child index/workfiles and unrelated parent
changes. The full upstream Base/Mine/Theirs submodule chooser remains unported.
See RESET-PARITY.md.

Finder exposes normal Resolve when cached conflicts fall within the selection.
Commit, Working Tree and workspace conflict menus dispatch the side choices.
Signed Finder activation and full selection/menu conditions remain unverified.

## Verification

The full suite passed 153 tests. Ten conflict tests cover current, mine/theirs,
binary, modify/delete, scoped selections, stale snapshots, rebase stage mapping,
symlinks, executable modes, initialized/uninitialized gitlinks and Finder scope
boundaries including conflicted submodule ownership. Original icon decoding also passed. The
final native layout and checkbox changes compile successfully.

Native QA in /private/tmp/TurtleGitResolveQA verified two initial checked rows,
partial/mixed checks, mixed-to-clear, clear-to-all and disabled OK with no checks.
OK with only README.md checked staged its manually resolved contents; the other
path stayed unmerged. HEAD, refs, every working file and all unrelated index
entries were compared to the captured baseline and remained identical. The result
sheet reported one resolved file and offered Commit. Context Resolved opened the
Yes/No question; No returned to the dialog. No and Cancel preserved HEAD, index,
status and every working file. After Cancel the window observation failed while
the app inventory still showed the preview running; parent restoration is not
claimed. The actual native capture is site/assets/resolve.png (1560 × 964).

## Remaining parity

Full three-way merge integration and the submodule chooser, upstream status-list menu coverage, drag/drop, temporary merge artifact
ownership and cleanup, progress cancellation/error continuation, branch identity
labels, broader native side-choice execution, stale
refresh/retry, Commit handoff, dark-mode/keyboard/Help QA, parent restoration,
signed Finder and sandbox runtime remain pending. Double-click now opens the native delete/modify chooser for a single ordinary
missing-side conflict (see DELETE-CONFLICT-PARITY.md); other conflicts still open
Compare with base rather than the full upstream conflict editor. All Resolve
workflow records remain partial; no complete dialog or App Store parity is claimed.
