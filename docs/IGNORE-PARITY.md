# Ignore parity

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`, `IgnoreDlg.cpp/.h`,
all ten `IDD_IGNORE` resource controls, `Commands/IgnoreCommand.cpp/.h`,
`CAppUtils::IgnoreFile/OpenIgnoreFile`, `GitStatusListCtrl` Ignore cases and
`TortoiseShell::InsertIgnoreSubmenus/MenuInfo`.

## Native dialog and entry points

The native window retains both upstream groups and all five radio choices:
containing-folder versus recursive matching, and root `.gitignore`, per-folder
`.gitignore` files or `.git/info/exclude`. OK, Cancel and Help follow below.
The initial choices are containing-folder matching and root `.gitignore`, matching
upstream's actual `OnInitDialog` radio selection (the constructor's destination
member differs). Frame position is saved; radio choices start from these defaults.
Native inspection found an intrinsic-size collapse; explicit content sizing now
keeps every label readable. The actual light capture is `site/assets/ignore.png`
(1100 × 664 pixels). The same radio layout was inspected in dark mode.

Commit and Working Tree unversioned/deleted file menus offer name/extension Ignore,
plus the single item's containing folder. Commit and Working Tree handoffs were exercised natively.
The workspace and Finder have name/extension Ignore and tracked Delete-and-ignore
variants. Finder builds submenus from cached states and dispatches the complete
selection; signed external Finder activation and full conditions remain unverified.
The original `menuignore.ico` is copied unchanged with recorded source/hash and GPL
provenance. These actions share that artwork.

Delete-and-ignore writes rules first, then asks `Keep file locally?` with Yes/No,
as upstream. Yes removes only index entries; No also removes local working files.
Failures offer OK to continue or Cancel to stop; prior ignore rules remain written.
The native result reports actual successful selected items rather than upstream's
loop-index count on failed items. This is a deliberate correction to the result,
not a change to the rule/removal order. Normal Ignore never stages or commits files.

## Rule generation and filesystem behavior

Containing-folder mode anchors each path relative to the selected ignore file.
Recursive mode writes an unanchored basename or extension mask; a local `.gitignore`
then applies only below that directory. Extension mode deliberately uses `*.` plus
the final extension, skips extensionless paths and suppresses duplicate rules.
Literal names escape backslashes, wildcards, brackets, comment/negation prefixes and
spaces, adapting upstream's Windows assumptions to legal macOS filenames. Filenames
containing CR/LF are rejected because line-based ignore rules cannot encode them.
These rules follow [Git's pattern documentation](https://git-scm.com/docs/gitignore).

Existing UTF-8 bytes, BOM, comments, permissions, inode and LF/CRLF endings survive
append. Destinations are read/validated before writes, and existing contents are
checked again before appending. Identical rules cause no rewrite. Non-UTF-8 files,
symbolic-link destinations, directories, outside/admin selections and nested
repository contents are rejected. Ignore file parent links cannot escape the working
tree; exclude parent links cannot escape Git's common administrative directory.
Git resolves the exclude path for linked worktrees rather than assuming `.git` is a
directory. Multiple-file writes are not a transaction: a later I/O failure can leave
previous successful appends in place, like upstream.

The access lease remains alive for the operation. Store builds require active scope
covering both the working tree and every rule destination. External linked-worktree
administrative destinations therefore need appropriate grants; signed runtime and
that permission flow remain unfinished.

## Verification

The full suite passes 140 tests. Six Ignore tests cover all scope/destination
combinations through real `git check-ignore`, unchanged index/local files, duplicate
suppression, exact BOM/CRLF append and permissions/inode, literal macOS names,
extension masks, validation before multi-file writes, symlinks, invalid UTF-8,
nested/bare rejection, linked-worktree common excludes and cached Finder eligibility.
Original icon decode/render tests also pass.

Native QA used disposable `/private/tmp/TurtleGitIgnore*QA` repositories. Cancel left
HEAD/index/status/all working files unchanged. Recursive/per-folder OK created
`Sources/.gitignore` containing exactly `StatusBadge.swift` and Git ignored the path;
prior files, HEAD and index remained unchanged. Dark Delete-and-ignore by extension
with exclude selected wrote `/Sources/*.swift`, displayed the keep-local question,
and Yes retained every working file while removing `Sources/Repository.swift` from
the index. HEAD and refs stayed unchanged. The success prompt counted one item.
Commit's expanded Ignore submenu displayed name, extension and containing-folder
entries. Selecting the name opened Ignore in front; OK appended exactly
`/Sources/StatusBadge.swift` to the root file, with unchanged HEAD/index.

Working Tree’s expanded Ignore submenu opened the extension variant in front;
OK appended exactly `/Sources/*.swift` to its root ignore file without changing
HEAD or index.

Several UI observations timed out or reported no available window after dialog
closure. The original preview still appeared running in app inventory. Git effects
are verified; restored parent selection/checks and post-close refresh are not claimed.

## Remaining parity and QA

Native error/retry, Delete-and-ignore No and error continuation, multiple destinations,
folder menu handoffs, signed Finder menus, saved position,
keyboard traversal, Help, broader appearance/locale and post-close restoration need
verification. Finder selection classes, directories/submodules, cache invalidation,
additional sandbox grants and full menu configuration remain partial. UnIgnore and
SVN Ignore are separate unported workflows. Interactive cancellation and streaming
progress are not implemented. No complete upstream or App Store parity is claimed.
