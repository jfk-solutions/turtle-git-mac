# TurtleGit for Mac — full port tracking

*A macOS fork of TortoiseGit*

The bundled [ZIP comparison](ZIP-COMPARISON.md) now connects default associations,
Advanced Restore Defaults, bounded ZIP64/Unicode metadata reading and a read-only
native inventory viewer. Raw Shift comparison and saved custom associations are
preserved. Fourteen focused Core checks and the real-archive native workflow pass.
Other Windows document scripts and full physical/signed acceptance remain open.

The [remote-management family](REMOTE-TAGS-PARITY.md#remote-management-operation-ownership--october-16-2026)
now owns tag confirmation, worker drain, ordered error acknowledgement and fresh
reload independently of its window. Remote-reference selection accepts once;
Add Remote captures submission and shows saving/cancelling state. Four native
case/engine pairs pass; physical and signed acceptance remain open.

The shared [path-entry family](PATH-ENTRY-PARITY.md) now connects source filesystem
completion to Clone, New Worktree, Rename and Export with native full-field
completion, owned directory reads, access scoping and retired-result guards.
Literal input, owner-icon Complete Path menus, caret ownership and native
completion Undo/Redo binding now pass across all four dialogs.
Physical keyboard/IME/popup and signed acceptance remain open.

The [application identity/file-open family](APPLICATION-IDENTITY.md) now packages
original app/document icons, full macOS icon slots, native patch/diff file-URL
routing and scoped document Save/Undo ownership. The website uses the same
artwork. Physical Finder/Launch Services and signed acceptance remain open.

The native [Dock progress family](DOCK-PROGRESS.md) now connects transport,
Commit, replay and shared local command progress, including unknown/paused/error
states, simultaneous operations, reduced motion and closed-window retirement.
Physical Dock and signed acceptance remain open.

Rebase/Cherry Pick Add and merge-parent preparation now share cancellable ownership,
atomic plan/draft publication, private multi-selection Log preferences and retired
question/picker callbacks. See [Add and mainline preparation](REBASE-ADD-PARITY.md#owned-add-and-merge-parent-preparation--october-16-2026).
Physical, full source and signed acceptance remain open.

Log range commands now follow source raw/displayed-row continuity through search,
graph projection and streamed rollback. Single/two-row exceptions remain; Compare,
Format Patch and Combine no longer treat hidden rows as adjacent selection.
Captured popup/Combine replies expire on projection replacement. See
[range selection](LOG-POPUP-VARIANTS.md#filtered-and-projected-range-selection--october-16-2026).
Physical, full consumer masks and signed acceptance remain open.

Changed Files and Rebase Revision Files now prepare Revert per file so copied/
missing historical files can use source Ignore/Abort and completed-count results.
Root comparisons expose empty-tree Revert, and historical export reads only the
chosen destination. See [connected recovery](SUBMODULE-DIFF-PARITY.md#per-file-recovery-and-empty-tree-revert--october-16-2026).
Physical, full copy/gitlink/Trash variants and signed acceptance remain open.

Create Branch/Tag now owns creation, cancellation questions, Switch acknowledgement
and description-only retry independently of the options window. Cancel drains
metadata/creation workers; forced closure closes its Switch sheet and refuses late
handoffs. Tracking-name suffix behavior and source tooltips are restored. See
[Branch/Tag completion](BRANCH-TAG-PARITY.md#owned-creation-cancellation-and-completion--october-16-2026).
Physical signing/transport, full visual and signed acceptance remain open.

Commit staging activation now closes the old preview, refreshes in the new mode
and presents the owned three-state explanation with the source's remembered hint
choice. Serialized mode/preview preference writes own cancellation, error/retry,
input and Quit lifetimes while preserving the draft, checks and index. See
[staging activation](COMMIT-PARITY.md#staging-activation-and-preview-preferences--october-16-2026).
The incremental staging follow-up now retains source rows/groups/status while
refreshing independent index state and partial previews. Whole-file rename and
unborn mixed-file unstage targets are corrected. See
[incremental staging](COMMIT-PARITY.md#incremental-staging-list-and-whole-file-targets--october-16-2026).
Full physical, amend and signed acceptance remain open.

Blame's annotation menus now capture line/text/parent/rename targets, honor owner
icon preferences and support Shift-F10/accessibility menu requests in both source
and gutter. Source and embedded Log invocations dispatch once and reject stale
document targets. See [annotation menus](BLAME-PARITY.md#captured-annotation-menus-and-keyboard-access--october-16-2026).
Full physical, visual, command-artwork and signed acceptance remain open.

RefLog now distinguishes full Refresh's missing-reference fallback to HEAD from
post-deletion row reload, and owns cancellable refresh/parent/unified reads through
actual worker drain. Delete/Clear confirmations, per-error sheets and exclusive
mutations retain their source defaults and closed-window/ Quit lifetimes. See
[RefLog lifecycle](REFLOG-PARITY.md#refresh-read-cancellation-and-deletion-ownership--october-16-2026).
Full physical, visual, menu/caller and signed acceptance remain open.

Repository Browser's revision picker now inherits its owner preferences/theme,
connects the shared selectable-Log actions and owns one modal selection lifetime.
The header shows source-style friendly reference labels while preserving pinned
objects; folder summaries include names and captured tree/file menu actions run
once. See [Browser revision selection](REPOSITORY-BROWSER-PARITY.md#revision-picker-labels-and-captured-actions--october-16-2026).
Full physical, visual, Finder and signed acceptance remain open.

Log Revert now preserves the original selected rows through its native workflow.
Mixed working-tree/root selections can undo the root; merge/stash batches keep
source Skip/Abort policy without guessing a mainline. Empty working-tree hashes
are skipped before Git, and earlier inverses/messages survive Abort. See
[Revert selection context](LOG-REVERT-PARITY.md#original-selection-context--october-16-2026).
Physical, complete caller, visual and signed acceptance remain open.


Log revision popups now follow source single/root/merge/multi-selection and
bare/working-tree command groups. The common Find/clipboard tail, captured Find
selection mark, synthetic working-tree clipboard and contiguous working-tree
comparison endpoints are connected. See [popup variants](LOG-POPUP-VARIANTS.md).
Full consumer-mask, physical and signed acceptance remain open.


Rebase's action row now has the source-ordered sticky bulk split button, corrected
oldest-commit Squash rules, canonical reference metadata tooltips and footer
Edit/Split placement. Completion also remembers its chosen command through the
shared native control. See [action controls](REBASE-ACTION-CONTROLS.md).
Full physical, visual and signed acceptance remain open.


Rebase's Revision Files pane now connects the Changed Files inspection family:
comparison/unified, Revert, history, Blame, historical Open/Save/export,
clipboard and independently saved native column layouts. Original status colors
and icons, root/parent snapshots and owner-bound cancellation accompany the
shared controls. See [Revision Files and native captures](REBASE-REVISION-FILES.md).
Full source-menu, physical and signed acceptance remain open.


Log-to-Rebase now carries the selected canonical branch/tag identity into native
options, including configured child Logs. Same-named tags cannot replace a
preferred local branch. Core commit-ID reads separate successful stdout from
warning diagnostics, retaining Git's typed-revision resolution. See
[Log parity](LOG-PARITY.md) and
[Rebase reference preparation](REBASE-REFERENCE-PREPARATION-PARITY.md).
Full dialog, physical Finder and signed distribution acceptance remain open.

The shared status-text family now preserves raw source colors and conversion
while adapting low-contrast dark text against composited native table backgrounds.
Working Tree and Commit count columns use their owning stores. The final Debug
build, pinned 29-input C++/settings oracle and both native engine cases passed;
nine real captures include live custom-color Apply pixels. See
[status text](STATUS-TEXT-APPEARANCE.md). Full physical, selected-row, all-dialog
and signed acceptance remain open.

The connected Log scope/information family now adds source revision endpoints,
file-selection and line/status totals, old/current-name word queries, hidden-file
selection cleanup and persisted Whole Project history/title/reopening with Follow,
busy and retired guards. Debug, five Core cases and both native engine cases
passed; current footer captures are reviewed. See [scope/information](LOG-FOOTER-PARITY.md).
Physical/signed and complete visual acceptance, including dark rename contrast,
remain open.

The Log filter/layout family now combines source-ordered native filter menus,
one-second typing, immediate clear/Return/Escape, actual ECMAScript validation,
owner preferences and cancellation/retirement/Quit accounting. Header and footer
commands follow the source layout; current light/dark compositor captures were
reviewed. Debug, eight Core tests and both native Git-engine cases passed. See
[Log filters](LOG-FILTER-PARITY.md); full physical/signed and complete Log parity
remain open.

The connected Finder overlay path-policy family now compiles source precedence
rules per refresh, follows per-directory volume/case metadata across mount
boundaries, resolves Finder badge aliases, refreshes on volume events and reports
precise include/exclude editor errors. Existing icon sets and handler choices
retain their shared Apply/Cancel workflow. See [overlay parity](FINDER-OVERLAY-SETTINGS-PARITY.md).
Real mount, physical Finder and signed acceptance remain open.

The connected transport selection family now uses the shared source/destination
reference browser in Push, private owned Log/RefLog selectors and repository-bound
commands, plus captured-draft and post-sheet handling across Push/Pull/Fetch/Sync.
Remote and branch names containing slashes retain their configured namespaces.
See [Push parity](PUSH-PARITY.md). Physical, authenticated-server and signed/App
Store acceptance remain open.

The connected file-history comparison family now reconstructs renamed endpoint
paths for Follow renames, shares direct native comparison preparation across
primary/picker Logs, preserves numbered-parent and live working content, and
uses recovered names for selected/parent/working unified diffs. Cancellation,
selection replacement and requested/forced Close share the owned reader lifetime.
See [Log parity](LOG-PARITY.md). Filtered/ambiguous merge walks, physical and signed
acceptance remain open.


The connected Changed Files action family now adds both-version Revert, Blame,
Export and child-submodule Log with source rename/deletion rules, pinned data,
owned folder/error/result sheets and protected checkout cancellation/Close
lifetimes. See [Changed Files parity](SUBMODULE-DIFF-PARITY.md). Revision entry now has delayed validation and native completion, shared owned
reference/Log/RefLog pickers, source query filtering and saved file-table layout.
Physical and signed acceptance remain open.


The connected Revision Graph command family now adds source menu groups and
one-use popup ownership, configured external unified viewers with captured Shift
choice and owned errors, selected-node Shift-F10 menus and native accessibility
nodes/selection actions. See [Graph parity](REVISION-GRAPH-PARITY.md). Physical,
third-party viewer and signed acceptance remain open.


The connected Log working-tree action family now includes Clean up and Abort
Merge, shared repository-bound primary/picker dialog routing, path-scoped Commit,
fresh merge/stash/submodule gates and cancellable metadata preparation through
Close/Quit. Revision Reset/Branch/Tag/Export availability follows the active bare
and stash source rules. See [Log parity](LOG-PARITY.md). Full consumer masks and
physical/signed acceptance remain open.


The connected Log inspection family now includes forward/reverse/symmetric range
Logs with path-aware child reuse, first-parent change-set comparison, continuous
multi-row endpoint comparison and merge-parent/combined unified choices. These
use the existing native Log and comparison dialogs, original menu artwork and
owned preparation lifetimes. See [Log parity](LOG-PARITY.md). Full source masks,
rename-following parent paths and physical/signed acceptance remain open.

The Log revision-menu family now binds 46 existing selectors to a one-use popup
snapshot, preserving native item artwork and typed payloads while rejecting
selection/reference changes, reload and retired/blocked owners. Fresh callbacks,
working-tree commands, byte-distinct refs and existing real Revert/Combine
workflows passed both grouped Git-engine cases. See
[menu ownership evidence](qa/log-popup-ownership-2026-10-15.json). Source menu
variants, physical/accessibility and signed acceptance remain open.

The Blame pane interaction family now adds saved native tab groups, group
auto-hide/pinning, caption drag sessions and outside-workspace floating with
captured-document guards. Native pane/File Open checks passed on both engines;
the final pane-only recheck passed after the documented layout/selector repairs.
Four current light/dark tab captures were reviewed. See
[pane evidence](qa/blame-pane-tabs-2026-10-15.json). Physical drag, full MFC docking
and signed acceptance remain open.

The workspace permission family now includes a native access manager under
File → Open Recent. It connects repository/extra-folder lists, independent stale
renewal, captured Add/Replace pickers and confirmed Remove/Forget, with workspace
and Quit guards and live-grant retention. Debug, 18 Core checks and both grouped
native engine cases passed; light/dark captures were reviewed after a sizing repair.
See [access guide](REPOSITORY-FOLDER-ACCESS.md) and
[evidence](qa/repository-access-manager-2026-10-15.json). Signed acceptance remains open.

Workspace opening now prepares external Git metadata permissions for linked
worktrees, submodules and shared object stores, with owned folder sheets,
per-repository saved grants, cancellation/rollback and child-window scope lifetime.
The final Debug build, 35 affected Core tests and both grouped native engine cases
passed. See [folder access](REPOSITORY-FOLDER-ACCESS.md) and
[batch evidence](qa/workspace-metadata-access-2026-10-15.json). Signed sandbox and
Finder acceptance remain open.

The connected Clone/Create Repository family implements owned browse/permission
sheets, captured submission choices, cancellable metadata discovery and guarded
warning/result lifetimes. Debug, six initialization tests and four unique native
cases passed after the recorded repairs. See
[batch evidence](qa/repository-creation-owned-2026-10-14.json); physical/signed
acceptance remains open.

The connected remote-manager family adds source Sync history cleanup on Rename/
Remove, timed native origin help, owned collision reads and draft-preserving
Push catalog refresh on manager return, with Pull/Fetch/Sync consumers. Its grouped
validation passed: Debug plus six native cases across system/bundled Git, with
all owned receivers reaped. See [batch evidence](qa/remote-management-family-2026-10-14.json);
full physical/signed acceptance remains open.

The connected Commit/patch/comparison preview batch implements movable sticky
previews, screen-aware placement, mode reuse, unwrapped patch extent/reset and
comparison navigation after viewport layout. Debug and six unique native cases
passed; two current light/dark preview captures are in the gallery. See
[batch evidence](qa/preview-viewport-2026-10-14.json). Full physical/signed acceptance
remains open.

The connected Push/Pull/Fetch preparation batch implements cancellable metadata,
source/remote replacement, Retry loading, close settlement and complete Push
preflight/post-hook ownership. Debug, 15 Push Core checks and six grouped native
cases passed after a real Core cancellation repair. See
[batch evidence](qa/transport-preparation-2026-10-14.json); full physical/signed
acceptance remains open.

The connected Statistics/Revision Graph continuation implements calculation close/
retry, source summary-control visibility, owned exports and destination scopes.
Debug and four grouped native cases passed; see
[batch evidence](qa/graph-workflows-2026-10-14.json). Full visual/signed acceptance
remains open.

The connected bundled SVN authentication batch implements five native callbacks
with combined credentials, explicit certificate details/trust, secure certificate
passwords and command-owned client-certificate copies. The pinned runtime retains
its dependency caches and records the native adapter/Keychain/plaintext policy.
See [authentication parity](SVN-AUTHENTICATION-PARITY.md). The certificate
inspection follow-up adds DER SHA-1/SHA-256, original artwork and an owned read-only
Open certificate sheet. Live server, other callers and signed/physical acceptance
remain open.

Native Issue Tracker Integration now connects its formerly missing association
page/editor and embedded provider to Commit, with project fallback, owned selection,
message/ID results, pre-commit checks and completion interfaces. The two settings
dialog families and Commit button have explicit partial native mappings.
See [native issue-provider parity](NATIVE-ISSUE-PROVIDER-PARITY.md); Windows COM
provider execution, vendor native ports and physical/signed acceptance remain open.

The connected working-file Revert recovery batch adds owned cancellable preparation,
streamed private-index Git output, captured progress closing policy, retained
Trash locations/action logs and fresh-status Retry. Forced retirement keeps
protected-step lifetime accounting while suppressing late results. See
[Revert parity](REVERT-PARITY.md) and the [user guide](REVERTING-FILES.md);
physical/signed and complete source acceptance remain open.

Workspace and Working Tree URL drops now connect the active upstream Move,
Move/Rename and Copy/Add choices to the existing operation windows, with captured
repository/destination context and owned preparation/picker retirement. See
[dropped-file transfer parity](FILE-DROP-TRANSFER-PARITY.md). Installed Finder
right-drag and signed/physical acceptance remain open.

The connected Rename/reference-management batch covers guarded file/folder Rename,
inline branch Rename, tracked-branch Set/Drop and ordered local/remote deletion.
Owned questions, cancellable streamed results, retained action logs and final
catalog/parent refresh now share operation lifetimes. Description retains its
source Input layout with captured-tip validation. See [Rename parity](RENAME-PARITY.md)
and [reference browser parity](REFERENCE-BROWSER-PARITY.md); these remain partial
family audits, with physical/signed and full upstream parity gates open.

The comparison configuration batch adds custom comment profiles in Application
Support and a native editor with draft/Apply/Cancel, validation and stale-edit
protection. Both viewers capture profiles on reload; the three-pane editor
retains its dirty Save/discard/Cancel workflow. See
[comment comparison parity](MERGE-COMMENTS-PARITY.md).

The merge locator batch adds colored Left/Bottom/Right stripes, viewport tracking,
nonselecting navigation, an optional fish-eye lens and saved native View/Settings
controls in both viewers. See [locator parity](MERGE-LOCATOR-PARITY.md).

The merge Save batch adds Backup original file and the source empty-result
Delete/Keep workflow to both viewers, including absent-file recreation and
deleted conflict staging retry. See [save workflow parity](MERGE-SAVE-WORKFLOWS-PARITY.md).

The whitespace display batch adds source space/tab/EOL overlays and original
CR/LF/CRLF icons to both viewers, with saved View/Settings controls and original
ending metadata preserved. See [display parity](MERGE-WHITESPACE-DISPLAY-PARITY.md).

The General settings batch adds native fixed-pitch font/size choices, live pane/
ruler metrics, an inline-diff length bound and source load-navigation flags.
See [General settings parity](MERGE-GENERAL-SETTINGS-PARITY.md).

The Merge Colors page adds native light/dark foreground/background controls,
selective defaults and shared palette updates across text panes, locator and
whitespace rendering. See [Colors parity](MERGE-COLORS-PARITY.md).

The Encoding/Go To batch adds the source nine/ten-choice native format sheet in
both viewers, atomic draft validation and source navigation bounds.
See [format dialog parity](MERGE-FORMAT-PARITY.md).

The native Merge Open dialog routes one/two standalone files, three-file merges
and unified patches/clipboard bytes through retained file permissions.
See [Open parity](MERGE-OPEN-PARITY.md).

The Merge Find/Replace family now uses native pane-local windows with the
source search options, Count, Replace/Replace All and grouped Undo/Redo in both
viewers. See [Find parity](MERGE-FIND-PARITY.md).

The About family now has native app/tool windows with original attribution,
selectable packaged runtime reports, source links and bundled license access.
See [About parity](ABOUT-PARITY.md).

The target is complete behavioral parity, with native macOS windows and Finder
integration. This first implementation establishes the architecture and common
workflows. It does **not** represent the complete port or reproduce all upstream
windows. No item is complete merely because its underlying Git command runs.

Format Patch's three export modes and no-prefix command are implemented in the
repository layer with seven tests, including binary mail patch
application. Its native dialog, live source-style progress and captured mail handoff have
hidden native verification with system and packaged Git; physical UI, full Send
Mail options and signed sandbox acceptance remain pending. See
[FORMAT-PATCH-PARITY.md](FORMAT-PATCH-PARITY.md) for the audited controls and scope.

Configured Send Mail's View Patch action now opens the highlighted file in a
read-only native unified-diff viewer, preserving its original bytes independently
of the Send checkbox. Shift uses the alternate viewer setting; owned reads,
missing-file recovery and close fencing have hidden native verification. Review and Apply now open independent native patch-review/serial-import tools
with inherited file grants; real working-tree application and two-commit import
have hidden native checks. Mail-client delivery, physical UI and signed grants
remain pending. See [Send Patch parity](SEND-PATCH-PARITY.md).

Direct mail now groups To/CC recipients by domain, resolves system MX exchanges,
and submits domain-specific envelopes while preserving full MIME headers. Retries
skip domains that already accepted the message; definite failures still permit
later domains to receive mail, while ambiguous uploads stop failover. Cancelling
a retry wait retains partial-domain acceptance.
Format and Import use the native Send Mail options/progress route for direct as
well as configured SMTP. Request Pull now uses that route with full ordinary
document text and a custom subject independent of Combine One Mail. Focused core tests, hidden native route checks and the
built SDK framework's private loopback queue passed. Public mail delivery,
mail-client parity and signed/physical acceptance remain unverified. See
[Send Patch parity](SEND-PATCH-PARITY.md).

Mail-client mode now shares native Send Mail options for Format/Import/Request
Pull and has a captured Apple Mail visible-draft adapter with separate To/CC and
immutable attachments. The client now retains recipient display names and applies
MAPI path-map attachment deduplication/UTF-16 ordering. Progress distinguishes draft preparation from actual mail
delivery. Actual Apple Mail, signed automation and full mail-client lifecycle
acceptance remain unverified. See [Send Patch parity](SEND-PATCH-PARITY.md).

The Log’s **Show branches this commit is on** action now opens a native modeless
reference dialog with containment filtering, original branch/tag artwork, one/two/
many selection menus, comparisons and owned Browse References/Log/Reflog pickers.
Targeted Core and hidden native checks pass; light/dark content captures are on
the website. Abort Merge progress now also has reviewed native control mappings.
Synchronization has native outgoing/incoming graph and file tabs, reference
changes, bounded transport output, separate checkout/fast-forward progress and
Fetch & Rebase source choices. Shift+Pull/Fetch opens owned full options and
refreshes results after dismissal. The backend covers nine source CLI actions;
the native Compare Tags tab adds sorting, icon menus, confirmed tag actions and
owned loading/command progress. Native Push variants and owned Shift Push options are implemented; project hooks, remaining
controls, full visual matching and signed acceptance are still pending. See
[Synchronization parity](SYNCHRONIZATION-PARITY.md).
Across the 130 inventoried dialogs:
120 dialogs have recorded partial family audits and 10 await a family review.
No dialog is certified complete. Of 1,659 static controls, 811 have recorded
native mappings and 848 still await control review. These are audit-coverage
counts, not a feature-completion percentage. See [all dialog coverage](DIALOG-COVERAGE.md).
See [the reference dialog audit](COMMIT-CONTAINING-REFS-PARITY.md).

Log commit ordering now has the source’s four-choice native sheet, deferred
header entry, draft OK/Cancel, Return/Escape and saved Git walk preference.
Core three-engine and native two-engine checks pass, including retained selection
and owned sibling/modal close behavior. See [the ordering audit](LOG-ORDERING-PARITY.md).

Abort Merge now owns its Changed Files sheet and opens a separate Reset progress
window, with mode-specific retry and cancellation through all owned reads.
Hidden controller and key-equivalent checks pass with system and packaged Git;
inspected light/dark content captures are on the website. Physical input, full
progress options and signed acceptance remain pending. Reset output now streams
through the shared bounded parser; the native selectable output adds original-icon
Copy/Copy All, error and link styling, current-work/percentage presentation and
a source-style completion footer with optional elapsed time. See
[the Merge follow-up](MERGE-PARITY.md#abort-merge-ownership-follow-up-october-10).


Git configuration now has a native Settings page with scoped source views,
identity inheritance, line-ending choices, three-state QuotePath/Prune and a
separate save destination. Implementation is still in progress and has not been
compiled or tested. Config editors and remembered sandbox directory grants are
implemented; their displayed and signed execution checks remain in scope.
See [the Git configuration continuation](GIT-CONFIGURATION-PARITY.md) and
[the unverified native Settings tree](SETTINGS-NAVIGATION-PARITY.md).

## Audited baseline

Worktree creation, listing, locking, unlocking, removal and pruning now have a
repository-layer port with disposable-repository tests. New Worktree has a native
dialog and create routing with actual model verification. Worktree List and
management menus now have native implementation and actual model verification;
full native/signed acceptance remains pending. See
[WORKTREE-PARITY.md](WORKTREE-PARITY.md).

Upstream: https://github.com/TortoiseGit/TortoiseGit

Commit: `7338078f8ddd924b8cddee35f512f2286072136d`.

The checked-in inventory covers 3,277 tracked entries and 130 dialog resources.
`upstream-files.csv` maps paths, blob hashes, review status, replacement and notes.
`upstream-dialogs.csv` lists dialog resources and captions, including the settings
pages and helper applications. Gitlinks must be recursively audited before using
those dependencies. Resources such as menus, icons, accelerators and strings also
require review; a dialog count is not a count of all upstream UI.

## Current integration verification

The latest complete local SwiftPM suite passed **980 tests, zero failures**, with
one optional MX probe skipped, on October 11, 2026. The system Git 2.50.1 / Swift
6.3.3 process exited normally after 874.897 seconds. It covers the recorded Core
checkpoint, including generated change-set comparison, but not native app UI.
The later Sync Find icon/resource addition passed the three focused MenuIcon
tests; the complete suite has not been rerun for that addition.
See [the complete Core checkpoint](qa/core-full-range-log-checkpoint-2026-10-11.json).
Recent Sync native checks, unsigned builds and bundle audits have separate
workflow records; these do not expand the Core result's scope.
These checks do not prove full dialog parity, activated Finder behavior, signed
sandbox execution, passing hosted CI on the latest source or App Store readiness.

## Architecture replacements

| Upstream component | macOS replacement | Current state |
| --- | --- | --- |
| TortoiseProc / MFC | SwiftUI windows, AppKit text views and file dialogs | First status, commit, log and operation views |
| Revision Graph | Separate decoration-simplified query, pinned universal OGDF layout adapter and native AppKit canvas/Filter/Find | Repository scopes, reduction, boundary nodes, pointer retention, colored boxes, selection, zoom/overview and Filter lifecycle implemented with focused native checks and light/dark captures. SVG/Graphviz and native raster/PDF exports implemented. Complete menus, export-panel grants, persistence and signed Finder acceptance pending. See REVISION-GRAPH-PARITY.md and GRAPH-LAYOUT-RUNTIME.md |
| src/Git | TurtleGitCore repository actor and installed Git | Basic status, mutation and patch operations |
| TortoiseShell / COM | Finder Sync extension and URL routing | Compiles; signed end-to-end behavior unverified |
| TGitCache | App Group snapshot, directory badge aggregation | Active repository polling; independent daemon pending |
| TortoiseMerge | Native three-pane UTF-8 conflict editor | Partial stage extraction, block choices and guarded saves; full view/menu parity pending. See TEXT-MERGE-PARITY.md |
| TortoiseGitBlame | Historical annotation reader and native annotated source window | Partial columns, age colors, Find/Go To Line and origin-aware Log; full menus, syntax, encodings and signed acceptance pending. See BLAME-PARITY.md |
| TortoiseIDiff | Native image comparison and three-pane conflict selection windows | Partial Load Images, linked sizing, overlay/XOR, transparency colors and frame playback; full source parity and signed acceptance pending. See IMAGE-COMPARISON-PARITY.md |
| TortoiseUDiff | Native patch window with highlighted text, find, appearance settings and printing | Partial File/View/menu behavior; full parity and signed acceptance pending |
| SshAskPass / TortoisePlink | Git helpers, Keychain and OpenSSH | Private agent, encrypted response, key/file grants and Clone/Fetch/Pull/Push/browse auto-load; pinned universal OpenSSH embedding and packaged Git client selection; remaining consumers, real authentication and signed acceptance pending |
| GitWCRev / COM | Native TurtleGitWCRev CLI, byte/UTF-16 templates and JSON automation | Repository/status/submodule reads, all source keywords and switches implemented; packaging added. Signed execution, exact libgit2 pathspec/locale behavior and broader automation acceptance pending; see WORKING-COPY-REVISION.md |
| TortoiseGitSetup | Signed app, extension registration, notarized distribution | Pinned universal Git build/embedding added; signed runtime and distribution acceptance pending |
| Languages / ResText | String catalogs and native localized resources | Pending |

## Behavioral parity backlog

| Workflow | First-pass implementation | Remaining upstream behavior |
| --- | --- | --- |
| Check for modifications | Native standalone Working Tree dialog; columns, scope/filters, statistics, dates, sorting, diff export and basic menus | Full menus, remote checks, progress/cancellation and persistent preferences; see STATUS-PARITY.md |
| Add | Native scoped checked list, ignored defaults, direct-file progress route, original icons/watermark, tracked history/Blame/base, unified diff, two-file comparison and temporary restoration/Revert menus, cancellable private-index add and index-only executable/symlink post-actions | Full menus, native visual/gesture/signed acceptance; see ADD-PARITY.md |
| Commit | Native checked-file dialog; optional three-state staging; amend, author, sign-off, statistics | Unsupported partial-stage file types, full history/completion, hooks UI, issue trackers, remaining action menu |
| Log | Native three-pane window; graph, refs, search/date filters, lazy action icons and metadata columns, working-tree row, per-parent file groups, comparisons and revision actions; scoped Add/Commit/Revert, index flags, Ignore/Delete and submodule history routes with actual receiver checks | Full reference chooser/search/walk/view/statistics controls, remaining context commands, group styling and selection-mark gestures, displayed light/dark/keyboard/VoiceOver acceptance and signed handoffs; see LOG-PARITY.md |
| Diff | Index/worktree/commit textual patches | Side-by-side, syntax highlighting, binary/image handling, external tools |
| Clone | Native Git/SSH/SVN option groups, captured progress/retry/cancellation, private-agent key loading and remote-key storage, URL/destination history, real Git tests and Log handoff | Full upstream progress, physical picker/Cancel/sheet QA, actual SSH authentication, real SVN/LFS, signed scopes and bare adoption; see CLONE-PARITY.md |
| Init | Native upstream Bare/text/buttons, .git default, destination warnings, real Git tests and normal/bare creation; bare workspace/Log | Picker confirmation, immediate adoption/recents, full bare menu behavior and signed integration; see INIT-PARITY.md |
| Fetch | Native remote/URL and three-state tags/prune, remote branch browser, shallow depth; real Git and native fetch checks | Full Rebase post-operation choices, settings/history, progress, authentication and broader UI QA; see FETCH-PARITY.md |
| Rebase | Native branch/action/list/tabs window; real Start/Skip and recovered Edit/Amend; tested persistent backend | Fetch/Pull handoffs verified; full recovery/advanced UI and conflict controls pending; see REBASE-PARITY.md |
| Pull | Native shared options window, squash/no commit and fast-forward choices; Git integration and native fast-forward/error checks | Interactive rebase, progress, full recovery and broader native QA; see PULL-PARITY.md |
| Push | Native upstream control order, branch/tag scope, remote/URL, force/lease, tags, upstream, recursion, server option; local Git tests and native branch/tag pushes | Full choosers/settings, progress, cancellation, authentication and broader UI QA; see PUSH-PARITY.md |
| Switch/Checkout | Native branch/tag/commit rows, create/force/merge/tracking/override options, real Git checkout tests | Complete choosers, progress and broader native QA; see SWITCH-PARITY.md |
| Branch / tag | Native name/revision/options/message controls; descriptions, annotated tags, optional checkout, force and tracking | Full choosers, signing prompts and broader native QA; see BRANCH-TAG-PARITY.md |
| Merge | Native revision/options/message window; real Git option/conflict tests and native No Commit → staging Commit verified | Message history, full choosers, progress/post-actions and native conflict recovery; see MERGE-PARITY.md |
| RefLog | Native five-column list, modeless Find, Log/Browser/Branch/Tag/Export revision handoffs, working-tree, selected-entry and previous-revision comparisons, clipboard formats, stash Apply and guarded general/stash deletion with partial-failure continuation | Full context menus/order, persistence, physical window/menu acceptance and broader native QA; see REFLOG-PARITY.md |
| Stash | Native Save options/warning plus direct Apply/Pop result prompts and Working Tree handoff; Git effects verified | RefLog list/inspection/selected Apply, guarded Drop/Clear and native replay Save/Pop implemented; reopened-session restoration, displayed acceptance and signed runtime QA pending; see STASH-PARITY.md |
| Finder | Original icons, separate menu preferences, cache badges, selection dispatch, scoped Diff/Log, source file/folder/selection clauses, direct two-file comparisons, recursive foreground submodule caches and root Rename/Remove, folder creation entries and targetless toolbar creation routing | Signed QA, remaining shell commands, watched-root management, cache daemon/FSEvents |
| Settings | Native 52-row Advanced draft editor with source defaults/validation and Apply/Cancel; Appearance and partial Merge Editor General: saved indentation and line-number defaults with Apply/Cancel; native Email delivery/server/port/encryption/auth controls and immediate app-private Keychain adapter | Remaining merge General/Colors, Git identity, tools, overlays, dialogs, hooks, credentials, networking, localization |
| Rename | Native source/name/browse/OK/Cancel, original artwork, versioned-file menus and guarded Git mv; mixed-file effects verified | Native browse, post-close restoration, submodules, shared-dialog consumers and signed Finder QA; see RENAME-PARITY.md |
| Clipboard / Copy and Add | Native URL clipboard, captured Paste Move, multi-file copy with collision and copied-repository choices, ordinary staging and owned streamed cancellation | Finder clipboard destination menu added with captured URLs and owned source authorization; physical gestures, drag menus, filesystem metadata and signed acceptance remain open; see FILE-TRANSFER-PARITY.md and FINDER-TRANSFER-PARITY.md |
| File Move / Move-Rename | Same-worktree destination picker, collision name sheet, ordered Git mv, Ignore/Abort, captured Commit/Working Tree remapping and streamed owned progress | Finder drag/clipboard and copy consumers, physical UI and signed acceptance; see FILE-MOVE-PARITY.md |
| Delete / keep local | Native confirmation, per-item Remove/Ignore/Abort, original icon and guarded Git removal; retained-copy commits/amendments tested | Native normal-delete execution, submodules, complete Finder conditions and signed QA; see REMOVE-PARITY.md |
| Ignore | Native five-radio upstream layout, original icon, app/Finder name/extension actions and Delete-and-ignore keep-local flow; real Git and native checks | Full menu conditions, native recovery/No/refresh and signed permissions; see IGNORE-PARITY.md |
| Reset | Native upstream revision/type groups, Log dispatch and initialized submodule reset/resume; real modes and native Mixed/Soft verified | Full chooser/diff-list, progress, native Hard/recovery and signed QA; see RESET-PARITY.md |
| Delete/modify conflict | Native fourteen-control conflict layout, keep/delete/Abort and side Log; exact Git effects and native keep/comparison/history verified | Full diff editor, Created/rebase/error/native Delete QA, parent restoration and signed scope; see DELETE-CONFLICT-PARITY.md |
| Resolve | Native checked list, current/mine/theirs, original icon and app/Finder dispatch; real Git and native checked-current/Cancel verified | Full conflict editor, remaining submodule chooser edge cases, progress, signed Finder and broader QA pending; see RESOLVE-PARITY.md |
| Send Patch | Source-style Core mail preparation: original headers/body, four inline/attachment and separate/combined modes, ordered checked inputs, To/CC and captured attachment bytes; MIME headers/body/attachments with independent parser and Git am checks | Native Send Patch options/checked-list/history foundation added; complete caller routing, patch-list production viewer/review/apply routing and signed drop grants; source sender capture API and native Email settings/credential adapter added, transport capture routing, broader MIME encoding/address acceptance, configured-server Core SMTP transport added with real loopback/TLS/authentication checks; ordered configured-server queue/retry added; configured sender/credential capture orchestration added; native configured Format/Import caller routing and progress added; native Action/Path notifications added; shared progress variants, direct MX, Mail client and actual signed Keychain acceptance remain pending; see SEND-PATCH-PARITY.md |
| Export | Native upstream ZIP/revision/scope options and separate result; verbose streaming, source-colored output/footer, Close/Abort, original Explore action, retained grants and atomic destination replacement; real Git and hidden native cancellation/owner checks | Physical options/sheets/keyboard/themes, full progress behavior, signed destination grants/Finder acceptance; see EXPORT-PARITY.md |
| Other commands | Log-selected reset, revert without commit and cherry-pick | Full options, conflict continuation/abort, resolve, bisect, clean |
| Patch workflows | Native Format Patch dialog and three repository export modes; progress and mail handoff compile | Native export/mail acceptance, apply patches, am continuation/abort, full review and email workflows |
| Repository Browser | Native lazy folder tree, pinned revisions, sortable Name/Extension/Size, historical file menus, marked comparisons and historical Revert, pinned child Log and historical drag representations | Multi-file Revert acceptance, actual Finder drops, broader submodule acceptance, dark/native action coverage and signed scopes; see REPOSITORY-BROWSER-PARITY.md |
| Submodule Add | Native source groups/history/browse, Branch/Force, explicit SSH key loading and child remote setting, app/Finder action | Clipboard defaults, displayed UI, complete progress, signed grants and real network; see SUBMODULE-ADD-PARITY.md |
| Submodule Sync | Original icon/app/Finder action, source non-recursive directory sequence, local URL config effects, owned live progress/cancellation and failure continuation | Displayed/full progress, signed parent/child access and Finder acceptance; broader SyncDlg remains separate; see SUBMODULE-SYNC-PARITY.md |
| Submodule Update | Native scoped options and separate owned progress, live output/cancellation, captured auto-close and successful bisect post-actions | Full progress, physical/signed/transfer acceptance and large command splitting; see SUBMODULE-UPDATE-PARITY.md |
| Advanced repositories | Native New Worktree and Worktree List with create/lock/unlock/remove/prune; partial submodule workflows | Native column gestures/appearance, Finder drop creation, native/signed acceptance, full submodules, git-svn and LFS |
| Helper apps | Partial native Blame, text Merge and unified Diff windows | Full helper parity, image diff, revision graph, askpass and revision/template tools |

## Porting method

1. Review a file and its related call sites, resource IDs, tests and documentation.
2. Record whether it is portable, requires a framework replacement, is an external
   dependency, or is Windows infrastructure with a documented macOS equivalent.
3. Implement its behavior in the named macOS module. Shared upstream logic can be
   retained as C/C++ where that reduces divergence; Windows UI is rewritten.
4. Compare native dialogs against upstream controls, options, defaults, shortcuts,
   error behavior and selection semantics. Preserve familiar workflow ordering and
   status colors while using macOS layout, menus and accessibility.
5. Exercise real Git fixtures for expected results and failure/conflict cases.
6. Mark a feature parity-complete only after all relevant source/resource mappings,
   behavior tests and UI acceptance checks pass. Platform exclusions need explicit
   rationale and a replacement or an acknowledged gap.

Every unreviewed file remains pending. The initial mapped command and dialog rows
are marked **partial**, not complete. A broad Swift rewrite still needs this
source-by-source audit; copying C++ files alone would not establish parity.

## Verification records

Recent Add receiver checks and unsigned build/package results are recorded in
[Add history](qa/add-history-2026-10-06.json) and
[Add missing-file comparison](qa/add-missing-pair-2026-10-06.json) and
[Add current-column clipboard](qa/add-current-column-2026-10-06.json) and
[Add unified diff](qa/add-unified-2026-10-06.json) and
[Add restoration copies](qa/add-restore-2026-10-06.json) and
[Add Revert](qa/add-revert-2026-10-06.json) and
[Revert progress table](qa/revert-table-2026-10-06.json) and
[Add index flags](qa/add-flags-2026-10-06.json) and
[Log search fields](qa/log-search-2026-10-06.json) and
[Log subject and case search](qa/log-search-case-2026-10-06.json) and
[Log filter selection](qa/log-search-selection-2026-10-06.json) and
[Log reference search](qa/log-ref-search-2026-10-06.json) and
[Log notes search](qa/log-notes-search-2026-10-06.json) and
[Log annotated-tag search](qa/log-tag-search-2026-10-06.json) and
[Log changed-path search](qa/log-path-search-2026-10-06.json) and
[Log history cancellation](qa/log-history-cancel-2026-10-06.json).
These checks do not establish full application parity, displayed-window acceptance,
signed Finder activation or distribution readiness. Workflow-specific parity files
record the remaining requirements.

## Earlier validation milestones

The following records describe earlier milestones. Test and icon counts belong to
those milestones; use the recent QA records for current validation scope.

`swift test` covers raw path parsing, renames/conflicts, stage/unstage including an
unborn branch, multiline commits and log parsing, working-tree diffs, literal
wildcard filenames, ignored files, linked worktrees, large output without deadlock,
failure propagation, blank message rejection, directory badge aggregation and
branch/tag/switch/merge/rebase argument compatibility with Git.

Manual UI checks on a disposable repository verified the branding, status list,
selected-file diff and history. They also caught and fixed an absent shared-cache
directory failure and a commit-layout issue that squeezed the file list.

The application, shared framework and embedded Finder extension compile using
`xcodebuild` with signing disabled. These checks do not establish Finder activation,
signed App Group access, accessibility, full UI correctness, credential prompts,
Intel compatibility or upstream parity.

## App Store preparation

Saved security-scoped repository permissions and a separate sandboxed AppStore
configuration have been added. The runtime selector requires a bundled Git engine
for that configuration. The pinned runtime build includes HTTPS helpers and source
material. See `DISTRIBUTION.md` for runtime acceptance, signing,
worktree permissions and license gates. These changes do not narrow the full-port
objective or establish App Store readiness.

The following paragraph records early bring-up at `1b66080`; its test/icon counts
and local toolchain problem are historical, not current release evidence. Current
feature-specific QA records live under `docs/qa`, and signed/hosted acceptance
remains separate from local unsigned builds.

The early Swift package built and 78 tests passed, including topological graph
continuity, root/merge/rename file statistics, annotated tag resolution, commit
search, and decoding all 37 original upstream icons. Finder source type-checks
with application-extension restrictions. The early local Xcode bundle build was blocked
by a missing CoreSimulator.framework in the Xcode installation. Subsequent local
Debug and AppStore bundle builds pass; that toolchain block is resolved. GitHub's macOS CI
successfully compiled the app and embedded Finder extension in both Debug and
sandboxed AppStore configurations at `1b66080`. Bundle validation confirmed all
32 original icons, their hashes and license, the shared framework, and the embedded
Finder extension in both configurations. The [CI run](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/37120088567)
also passed the 24 Swift tests. Signed Finder appearance remains unverified.

Finder requests now carry all selected paths as repeated URL fields, preserving
literal filename characters. One security grant must contain every item; each
item's containing repository is checked before replacing the current session or
running a command. Mixed and nested repository selections are rejected. Selected
folders expand to changed rows using path component boundaries. Finder Diff uses
the requested paths even when no status rows exist, and Log accepts multiple path
filters with a Show Whole Project checkbox. The commit dialog now keeps checked files separate from highlighted rows.
Checkbox mode commits selected working-tree files; staging mode commits the index.
Other upstream shell commands remain pending. New tests cover URL parsing, legacy requests, malformed input, directory
selection, literal multi-path history, and clean-file diff isolation.

The Commit window now follows the upstream message-above-file-list arrangement,
with category check links, original status icons, line counts, amend, author and
sign-off controls. Its optional staging support uses native three-state checkboxes
in the same file list. Git integration tests cover unchecked index preservation,
unborn commits, staged rename/deletion, amend with no checked files, custom author,
sign-off, partial index contents, and rejection by a pre-commit hook. A native UI
commit on disposable sample data committed only README.md and left the unchecked
Sources/Repository.swift change staged. Native staging checkboxes, mixed-state rendering, stage/unstage of an unversioned
file and an index commit preserving later working-tree edits were also exercised
on disposable sample data. The right-hand patch window now stages/unstages selected lines and hunks in
tracked UTF-8 text files, with native UI and real Git integration verification. See COMMIT-PARITY.md for remaining parity.

Submodule conflict chooser now has native Base/destination groups and choice
actions, with 167 passing tests and actual light/dark captures. See
SUBMODULE-CONFLICT-PARITY.md for the remaining full-port requirements.

Resolve now matches upstream file-to-gitlink checkout and failed submodule
removal Delete/Abort choices, with native Abort/Delete and recoverable Trash
verification. Remaining type transitions, registered/multi-item removal and full
progress still require audit.

Text merge source panes now align base removals, additions, conflicts and gaps
with upstream light/dark colors and original source line numbers. The latest
full suite passes 180 tests; alignment tests reconstruct exact source contents
over exhaustive and seeded Unicode/CRLF cases. Actual native captures verify
the palette and layout. Full libsvn segmentation parity, source scrolling QA
and broader keyboard acceptance remain incomplete; see TEXT-MERGE-PARITY.md.

The text editor's source context menus now expose Use this whole file with
undoable original-stage replacement. Native Mine/Theirs, keyboard Undo/Redo and
unsaved-close Cancel are verified. Reload now exposes existing stage reload
with original artwork and history reset; its native dirty prompt/Cancel are verified, while confirmed reload remains
pending. Full source-block selection and upstream EOL handling are still partial.

The merge Reload prompt now includes Save before Reload. A real-Git regression
test verifies Unicode/CRLF/EOF draft saving followed by conflict regeneration
without changing unresolved stages or unrelated data. Native Save and Reload
saved exact Mine contents; final view/history acceptance remains pending.

EOF conflict choices now retain original missing-final-newline metadata across
saves, with five real-Git ending combinations and native combined-choice Save
verification. Upstream EOL normalization and native CRLF/Undo/resolve coverage
remain partial.

The text merge result now offers the upstream nine-style line-ending submenu
with reversible conversion. A shared UTF-16 scanner fixes CRLF marker detection
and caret line numbers. Native CRLF → LF, Undo/Redo and unresolved Save warning
were verified; complete EOL/encoding metadata and exotic native combinations
remain partial. See TEXT-MERGE-PARITY.md.

The text merge context menu now includes upstream leading tabs/spaces
conversion and Trim right, with single-step Undo and conditional availability.
Native conversion, Undo and exact Unicode/CRLF Save bytes were verified.
Global tab-width preferences, EditorConfig and locale-specific Unicode trim remain
pending. See TEXT-MERGE-PARITY.md.

The merge editor now has independent 1/2/4/8 tab-width menus in each pane.
Native width changes preserved clean state and Undo history; merged-result
conversion and Save bytes at width eight were verified. Global persistence,
global insertion-mode preferences and EditorConfig remain pending.

Merge pane menus now include Tab/Space and Smart tab char. Native Space
insertion, nearby-tab Smart choice, multiline Tab/Shift-Tab, Undo and exact Save
bytes were verified. Global preferences, EditorConfig, precise partial-column
selection restoration and broader key/view behavior remain pending.

Advanced Settings now has a native Name/Value editor for all 52 registered
source settings, with source defaults, deferred Apply and blank-value reset.
Most setting consumers, the complete settings host and native/signed acceptance
remain pending. See [ADVANCED-SETTINGS-PARITY.md](ADVANCED-SETTINGS-PARITY.md).

The October 10 Abort Merge control audit maps its nine already-implemented native
roles from pending review to partial. This is an inventory correction, not a new
completed dialog: modal comparison, Quit/forced-close cancellation and separate
options/progress windows still need work. See
[the owner audit](qa/merge-abort-owner-audit-2026-10-10.json).

## Hosted Git runtime dependency order (October 11, 2026)

The macOS workflow now builds pinned universal Git before the Debug application
and all tests that explicitly select the bundled executable. Previously the
Synchronization and Log checks appeared before that build, which left their
Git path absent on a clean checkout. The move preserves all other steps.
Local ordering checks pass; hosted execution remains pending. The observed
prior macOS job was queued with no assigned runner, whose cause is not yet
established. See [ordering verification and hosted limits](qa/ci-git-runtime-order-2026-10-11.json).

## Git/LFS deployment validation (October 11)

Hosted run 38160034341 passed the repaired universal graph build and then failed
on the Git LFS deployment-target count. The old validator counted `minos` lines
from default `otool -l` output across a universal file. The log does not include
raw load commands, so the exact host-output cause remains unproven.

The replacement reads each architecture's Mach-O deployment command directly,
accepting modern macOS `LC_BUILD_VERSION` and legacy `LC_VERSION_MIN_MACOSX`. It
requires one target per slice, validates command bounds/platform, and enforces
the pinned maximum macOS version independently. Publisher LFS provenance and
dependency gates remain intact. Three regression tests and explicit per-slice
otool comparisons for real Git/LFS pass, as does the full local Git runtime
audit. Hosted Intel execution is still required; this is not a green CI claim.
See [the deployment record](qa/ci-git-deployment-2026-10-11.json).


### Implementation and validation cadence

The requested cadence is to implement a complete major port section before
building and testing it. Small command groups and individual dialog edits are
not separate validation milestones. Accumulate the related UI, menu, icon,
backend, ownership and documentation work, then run a combined verification
pass for that section. During implementation, read the pinned upstream source
and review diffs; defer builds, native receivers, bundle audits and broad suites
until the section is ready. Correct a concrete failure from that pass and rerun
only the affected checks. Reuse completed evidence within its proven scope.
Always close the owned test receiver and child processes when a check ends.


### Shared Settings section, 2026-10-11

Implemented native host OK/Cancel/Apply with page-ordered draft participants for
currently available pages, asynchronous Git/Remote saves, failure-page selection,
input shielding during save and a termination guard. Dialogs/Commit no longer
persist every click in this host. Color, font, viewer, history-limit and saved-data
preferences participate; Unified Diff retains both subpage drafts. Standalone
settings retain their local controls. Remote immediate actions remain immediate.

Validation was grouped after the implementation batch: Debug build passed and
three focused Git configuration tests passed. No app/native receiver was launched
and no full suite was rerun. Native workflow/visual/sandbox acceptance remains
open; see `qa/settings-history-batch-2026-10-11.json`. This does not certify any
additional inventory dialogs or the full port.


### Dialogs 1/2 source continuation, 2026-10-11

Added working source Describe strategy/format/first-parent controls, optional
asterisk message sections and abbreviated rename presentation. Split implemented
Misc/Commit preferences into Dialogs 2 and isolated Message Editor extras; aligned
Commit with the source shared history-limit key. This is the next major section
in progress, with source/diff review only. Builds, tests and app launches remain
deferred until the rest of this section is implemented. Remaining behavior and
acceptance is listed in SETTINGS-NAVIGATION-PARITY.md; no inventory certification
has changed.


### Dialogs 2 behavior continuation, 2026-10-11

Connected remaining source Misc preferences to .mailmap display/clipboard,
validated FETCH_HEAD picker entries and detached/new-branch checkout semantics,
source Sync position sequencing, reversed native tag choices and shared operation
sounds. Explicit raw amend-author reads prevent display mailmaps from changing
author identity. Added source timeout/history Apply validation. Native sounds are
enabled only by actual application startup, not headless logging installation.

This extends the same major Dialogs section without a new build, test or app
launch. The next section work is persistent Log cache and Dialogs 3; combined
validation follows implementation. Details and acceptance limits are in
SETTINGS-NAVIGATION-PARITY.md. Inventory remains unchanged.


### Log cache and Dialogs 3 backend continuation, 2026-10-11

Added persistent opt-in Log changed-file caching and its source checkbox, with
configuration/tree/index/attribute invalidation, cancellation fencing, bounded
atomic records and Git fallback on cache failure. Added all five Dialogs 3 project
settings with source scopes/inheritance, .tgitconfig hierarchy, bare HEAD reads
and source-ordered writes. Native page/editor integration remains in progress.

No build, tests or app launches were run for this continuation; validation stays
with the whole Dialogs section. See LOG-CACHE-PARITY.md and
SETTINGS-NAVIGATION-PARITY.md for implementation scope and open acceptance.


### Development cadence and General/setup batch, 2026-10-11

Implement substantial feature sections before grouped validation. Repeat checks
only for failures, meaningful subsequent changes or unresolved concerns. Close
every app instance launched for testing. Avoid full-suite or UI relaunch loops
between small edits.

The General engine preferences, update checking and five-stage First Start Wizard
were validated together: Debug native build exited 0 and 13 focused Core tests
passed. Compile failures were repaired within that checkpoint. No app was
launched. Native, network and sandbox acceptance remains open; see
`qa/general-setup-batch-2026-10-11.json`. Full-port certification is unchanged.


### Credential settings implementation batch, 2026-10-11

Implemented scoped/origin-aware credential configuration, exact-file advanced
writes/removal, simple helper choices with confirmed simplification, native
source-layout controls, original credential icon, shared Settings Apply/Cancel
and the First Start Wizard's owned Advanced credential sheet. Keychain Access
replaces Windows Credential Manager. No build/test/app launch was run for this
continuation; validation is deferred to the authentication-section boundary.
See CREDENTIAL-SETTINGS-PARITY.md for current behavior and acceptance limits.


### Authentication section checkpoint, 2026-10-11

Added the native SSH Key Generator using bundled OpenSSH and owned wizard/menu
entry points, secure passphrase helper channels, exclusive key-pair publication
and cancellable process cleanup. Validated together with the preceding credential
settings batch: Debug native build exited 0; 17 focused Core tests passed. No
app or full suite was launched. Remaining native/sandbox/source utility parity
is recorded in SSH-KEY-GENERATION-PARITY.md and
`qa/authentication-settings-batch-2026-10-11.json`.


### Network settings implementation batch, 2026-10-11

Added source-layout Network controls, global proxy configuration and retained
disabled drafts with Keychain password storage, custom OpenSSH bookmarks and
validation, shared Apply/Cancel, actual Git process environment integration and
the original source icon. No build, tests or app launch were run for this
continuation; validation remains grouped with the next Finder-settings section.
See NETWORK-SETTINGS-PARITY.md for behavior and remaining acceptance.


### Finder overlay settings and Network checkpoint, 2026-10-11

Added source-grouped Icon Overlays/Overlay Handlers pages, original artwork,
volume/path filters, handler suppression and unversioned/subrepository folder
propagation. Direct overlay entries are cached independently of raw menu status;
App Group preferences and notification reloads drive the extension. Validated
with the preceding Network batch: native Debug build exited 0 and 22 focused
Core tests passed. No app or full suite was launched. Remaining source/native/
signed acceptance is in FINDER-OVERLAY-SETTINGS-PARITY.md and
`qa/network-finder-settings-batch-2026-10-11.json`.

### Finder icon/index/menu continuation, 2026-10-11

Ported all 16 source overlay icon sets (144 original ICO files and per-set notices)
with native List/Symbols previews and shared Apply/Cancel selection. Finder reloads
all nine badge images on set changes. Main/submodule snapshots now retain Git
skip-worktree and assume-unchanged flags, with source normal-state precedence and
handler toggles. Subtree refresh clears stale flags and preserves independent
repositories. Known roots retain versioned menus despite aggregated untracked or
ignored status; untracked files keep Add eligibility. One grouped native build
exited 0 and 34 focused tests passed, zero failures, with no app launch. Native
Finder/UI/signed acceptance and complete source certification remain open; see
`qa/finder-icons-batch-2026-10-11.json` and FINDER-OVERLAY-SETTINGS-PARITY.md.

### Context Menu settings continuation, 2026-10-11

Added the two upstream Context Menu pages with all 55 source list entries,
original command icons/labels/64-bit IDs, page-specific defaults and one shared
Apply/Cancel draft. Implemented commands can move to Finder's main menu, stay in
the TurtleGit submenu or require Shift. Hide-unversioned and source-specific
path exclusions now apply before command capture, including mixed selections.
Grouped Ignore/Bisect/Merge commands share source preference IDs; empty submenus
are omitted. The toolbar remains flat. Advanced icon preferences preserve saved
menu policy and stale page drafts re-read the current icon choice on Apply.
Unavailable Finder commands and drag-menu integration remain explicit. See
CONTEXT-MENU-SETTINGS-PARITY.md for the source comparison, validation and remaining
native/signed acceptance. The full port remains incomplete.

### Finder command and native Settings ownership continuation, 2026-10-12

Added eight source menu entries and their original clauses/order/icons: Sync,
previous-version Diff, parent gitlink Log, Blame, conflict editor and application
Settings/Help/About. Previous Diff uses source path-history semantics and immutable
directory comparison/patch scope. Submodule-folder Log revalidates registration
and authorizes the parent. App/Finder Settings now share a native property-sheet
owner; global requests suppress local config sources and known-repository requests
retain normal authorization. Dirty/busy context switches retain existing drafts.
The source catalog now exposes 47 groups; eight commands remain unavailable.
See FINDER-COMMAND-HANDOFF-PARITY.md for grouped evidence and remaining physical/
signed acceptance. The full port remains incomplete.

### Finder LFS and mail continuation, 2026-10-12

Added source LFS group and its three inner actions using cached marker metadata,
original icons, shared placement/Shift policy and fresh literal versioned-file
preflight. Existing LFS results/Force/cancellation/Pull/Quit flows now support a
standalone progress owner. Send Mail launches the native composer outside Git
with file/root grants and an exclusive owned global-sender context; opening it
does not submit mail or change the active checkout. Outside-repository Review/
Apply chooses a target working repository with owned-sheet/late-reply fencing.
The catalog exposes 49 groups; six remain unavailable. Native LFS/mail receivers
now compile once and run together. See FINDER-LFS-MAIL-PARITY.md for exact source,
validation and remaining signed/physical/patch-review acceptance.


## Git daemon batch — 2026-10-12

Daemon now uses the upstream warning/remember-choice and serving defaults, with
a native progress window, URLs, bounded output, cancellation and process-tree
cleanup. App and Finder commands share one window per root, including bare
repositories, source icon/conditions/order and menu preference mapping. The
catalog now exposes 50 of 55 groups; four SVN groups and Review Patch remain
unavailable. Incoming-network entitlement is configured, with signed sandbox,
physical layout, firewall and LAN/IPv6 acceptance still open. See
[DAEMON-PARITY.md](DAEMON-PARITY.md). Validation is grouped after the complete
implementation batch, using loopback-only real Git serving and native receiver
fixtures; no installed app or Finder extension is activated.


## Single-patch review and directory-target batch — 2026-10-12

The missing Review/apply single patch Finder group now routes to native owned
patch/target choosers and the existing before/after editor without adopting a
repository or applying on launch. Source artwork, single-file/Extended clauses,
placement before Send Mail and shared menu preferences are retained. Directory
mode supports plain targets and nested Git folders, anchors patch paths via
disposable administration, preserves the real index during application and
avoids initializing Git in ordinary folders. Edited new files auto-add only
when the target is a Git working tree. Outside-repository Send Mail Review uses
the same workflow; serial import still chooses a working Git repository.
The Finder catalog now exposes 51 of 55 groups; the four SVN groups remain
unavailable. Full clipboard/path-guessing/TortoiseGitMerge behavior, physical
layout and signed acceptance remain open; see REVIEW-PATCH-PARITY.md.


## SVN workflow/runtime batch — 2026-10-12

All four remaining Finder groups now have native routes: source DCommit radio/
remember/stash flow, Fetch with captured Diff/Log, source fetch/fast-forward/
Rebase handoff and both Ignore destinations. The common svn/.metadata marker is
cached with backward-compatible decoding, exact source clauses/order/icons and
original preference masks. The catalog now has implementation routes for all
55 groups; this does not certify full application/dialog/Finder parity.

The previously disabled git-svn stub is replaced by a relocatable universal
dispatcher and private per-CPU Perl/Subversion/Serf/OpenSSL runtime, with pinned
sources, notices, reconstruction, hashes, contained dependencies and macOS 13
deployment. Real private file:// clone/fetch/dcommit/ignore validation passed
with build-prefix fallbacks hidden. CI builds the interpreter component on
Apple Silicon, transfers a permission-preserving tar payload, and retains the
Intel main test job. Remote CI, signed inheritance/trust/credentials, physical
dialog matching and release review remain open; see SVN-PARITY.md and
GIT-SVN-RUNTIME.md.


## Clipboard patch and target-matching batch — 2026-10-12

The diff viewer copies original patch bytes into native/legacy custom formats,
and File → Review Clipboard Patch captures that snapshot before its owned target
chooser. Single-patch preparation now follows the upstream current/ancestor/
immediate-child/directory matching order and strict one-third threshold, with
Suggested/Selected/Cancel confirmation and permission-bounded searches. Git
headers use p1 and plain unified paths p0. Preflight cancellation/late-reply
fences retain the existing target grants and Quit ownership. Remaining Open
accessory/Finder clipboard/format/physical/signed gates are recorded in
PATCH-CLIPBOARD-TARGET-PARITY.md; the complete port remains active.

Development cadence requested by the user: implement substantial connected
feature batches before validation. Run one relevant grouped validation pass
at the batch boundary; repair actual failures with focused checks. Do not
repeat broad suites after successful checks without new changes or unresolved
evidence. Reuse native receiver compilation where possible and retire all
test-owned windows/processes when verification ends.

## Merge regex filters batch — 2026-10-12

The native filter-list and Name/Regex/Replace editor dialogs now connect to
two-pane comparisons, window-local filter selection, the bundled ECMAScript
replacement engine and original light/dark green filtered-row colors. Comparison
keys are separate from original source bytes and writable drafts. The complete
batch includes persistence/cancel, validation errors, cancellation, stale-reply
fencing, annotation remapping and owned-dialog cleanup before grouped checks.
Three-pane filtering and complete source/signed acceptance remain open; see
MERGE-REGEX-FILTERS-PARITY.md.

## Subversion merge engine foundation — 2026-10-12

The pinned Subversion diff2/diff3 APIs now have a universal native adapter, typed
Swift source ranges, optional ECMAScript keys, original line retention, bounded
cancellation/output validation, source/license reconstruction and app/CI build
integration. It shares existing GitSVN libraries. Twelve focused Core tests and
actual embedded arm64/x86_64 loading passed after implementation. Current editor
alignment and Git-generated result text are not switched yet; that integration
and resolved conflict children remain necessary work for source parity. See
SUBVERSION-MERGE-ENGINE.md.

## Three-pane engine and regex integration — 2026-10-12

Native conflict preparation now consumes Subversion ranges for source rows and
result generation, preserving original Mine/Theirs text, removed Base rows,
one-side gaps and filtered green rows. Window-local regex choices regenerate
only through the dirty Save/discard/Cancel workflow. Native Undo, successful
reload history reset, Save-before-Reload, explicit resolution and preparation
Close cancellation passed after a complete implementation batch. Core snapshots
retain engine source rows across saves; staged/working/HEAD checks pass. The older
Swift compiler's Remote Settings nested-defer actor error from CI was repaired.
Resolved children, two-pane conversion and physical/signed acceptance remain
open. Offscreen capture omitted SwiftUI toolbar text; those images were rejected.

## Two-pane engine and editing integration — 2026-10-12

Two-pane ordinary/filtered comparisons now request Subversion ranges while
retaining immediate native editing coordinates. Debounced requests cancel stale
work, preserve source selections and remap annotations before publishing the
authoritative result. Transfers/navigation/inline diff wait for completion;
engine errors clear alignment instead of silently using the projection. The
batch includes native typing, Unicode selection, Undo/Redo, marked Save and
encoding/EOL preservation checks. Source-engine resolved children, full options,
complete captures and physical/signed acceptance remain open.

## Resolved-child metadata and source padding — 2026-10-12

Protocol 2 exports Subversion's resolved children with their parent IDs and
validates side partitions, containment and repeated parent Base ranges. The
source rendering follows DiffData.cpp's first-child padding rule; parent result
blocks remain unresolved, including shared child lines. This corrects the earlier
assumption that the source split those parents into smaller resolved results.
Original numbered lines and block choices are preserved. Full source option,
segmentation, physical/signed and visual-capture acceptance remain open.

## Comparison options and settings batch — 2026-10-12

Both comparison workflows now expose source whitespace choices, Ignore line
endings and Ignore case, with saved defaults in Merge Editor settings. Defaults
retain source IgnoreEOL=true, case-sensitive and compare-whitespace behavior.
Original text/encodings stay separate from normalized keys. Three-pane changes
use the dirty reload transaction and persist only on success; two-pane changes
preserve drafts and recompute with existing cancellation/selection gates.
Comment profiles, Unicode locale equivalence and physical/signed acceptance
remain open; see MERGE-COMPARISON-OPTIONS-PARITY.md.

## Comment profiles and comparison batch — 2026-10-12

Pinned original profiles, extension precedence and the source UTF-16 comment
heuristic now feed comparison keys before regex/whitespace/case conversion.
Both viewers expose Ignore Comments only for supported extensions. Original
text/bytes and existing dirty reload/save/Undo flows remain separate. Core and
combined native checks pass after the connected implementation; original profile
packaging is verified. Source quote limitations are documented, with bounded
cancellation added. Overrides and physical/signed acceptance remain open; see
MERGE-COMMENTS-PARITY.md.

The two-pane Merge viewer now has a source-style Line Diff Bar: saved visibility,
Base/Mine pointer preview, forced inline/whitespace colors, original EOL markers
and horizontal-scroll alignment. See [Line Diff Bar parity](MERGE-LINE-DIFF-PARITY.md).
Physical whole-window layout and docking acceptance remain open.

Merge General's source Misc/Diffing grouping and signed patch-context setting
are now wired to the two-file Create patch file workflow, native File command
and owned Save panel. Git no-index output retains saved bytes/modes and quoted
comparison names, independently of unsaved drafts and display filters. See
[Create patch parity](MERGE-PATCH-PARITY.md); General and Colors remain partial.

Merge Colors now has all 17 source color channels with native wells,
Automatic/More colors menus, selected-channel/palette restore, independent
Light/Dark drafts and shared Settings Apply/Cancel. Owned color panels release
on page/window closure and fence late actions. See
[Colors parity](MERGE-COLORS-PARITY.md); physical/full-page acceptance remains open.

The combined Merge view now projects source removal/addition ordering into one
native editor with Mine edits, removed-row payload retention, Save/Undo/Redo,
mode-switch dirty prompts, a saved General default and combined locator/navigation.
See [one-pane parity](MERGE-ONE-PANE-PARITY.md) for state/menu/physical acceptance
that remains open.

The one-pane context menu now follows the source left-view role. Hidden-opposite
transfer operations are gated, right-view mark actions are omitted, and clipboard
commands retain their own pasteboard/editor context. Source-ordered encoding
menus dispatch by format identity. See
[context parity](MERGE-ONE-PANE-CONTEXT-PARITY.md); physical popup/full-menu
acceptance remains open.

Merge General's Default to UTF-8 control now shares the source detector with
completion scanning and feeds two-pane, Git conflict and standalone three-way
loads. Legacy Windows-1252 input can load/save losslessly; generic Core callers
retain their original detection defaults. See
[default encoding parity](MERGE-DEFAULT-ENCODING-PARITY.md) for locale/malformed
and remaining load-caller acceptance.

Merge viewers now provide saved long-line wrapping, native width/font/tab
reflow, horizontal-scroll gates and shared wrapped heights across aligned
source rows. Combined/result panes retain logical editing offsets. See
[wrapping parity](MERGE-WRAPPING-PARITY.md); full result-row alignment,
unchanged-section collapse and physical/large-file acceptance remain open.

Network settings now have grouped native verification of private real Git
writes, credential-cache boundaries, source-ordered partial failures and
Settings validation/Cancel. Forced deactivation no longer reactivates after
Apply, and late reads cannot touch the password cache. The Network resource is
reviewed as a partial native replacement; production Keychain/physical/signed
acceptance remains open. See [Network parity](NETWORK-SETTINGS-PARITY.md).


Credential settings now retain destination-only draft edits and restore the scope
on Cancel. Captured saves and read/selection responses are fenced on retirement;
Settings Apply does not reactivate a closed page. Private native receivers passed
with system and bundled Git, covering helper resets/chains, scoped copy,
confirmation choices, Remove, None and lifecycle. The Credential resource is
classified as partial; physical layout, production Keychain and signed acceptance
remain open. See [Credential audit](CREDENTIAL-SETTINGS-PARITY.md).


Advanced external tool associations now use a native AppKit table with sorted
Extension/Program columns, visible argument templates, double-click Edit routing
and source-style next/previous selection after Remove. Diff/Merge parent settings
share an explicit draft/validation/persistence model. Private native checks cover
association editing and shared Settings Apply/Cancel; actual receiving-app launch,
Windows-script replacement, exit-code trust and signed grants remain open. The
Advanced, association editor and Merge Tool resources are partial replacements,
not certified complete. See [Tool settings audit](DIFF-TOOLS-PARITY.md).


Blocking external Merge launches now own their wait/confirmation lifecycle.
Caller close and cancellation release TurtleGit's wait, preserve the external
application, and fence late Mark Resolved responses. Private native checks with
both Git engines verify exact working-byte staging and stale-stage refusal.
Actual external app/KVO/signed acceptance remains open; see the Tool audit.


Overlay settings now scroll within small native hosts; handler rows use the
selected source icon set. Shared draft validation, publication and unsigned
notices have private native acceptance across all three pages. Publication failure
retains the draft without saving local preferences or notifying Finder. Icon
Overlays, Overlay Handlers and Icon Set are partial native replacements; signed
extension refresh, mount handling and full physical layout remain open. See
[Overlay settings audit](FINDER-OVERLAY-SETTINGS-PARITY.md).


Email Settings now has explicit model ownership in the shared Settings host;
credential work blocks page switches/dismissal and app Quit. Forced host
retirement invalidates its model, fencing late credential responses. The existing
private Email receiver now joins the object-linked group and additionally checks
shared Apply/Cancel/busy validation and Quit gating. Email is a partial native
replacement; real Keychain, physical credential sheets and mail/signed acceptance
remain open. See [Email audit](SEND-PATCH-PARITY.md).


Commit progress now includes the source's conditional SVN DCommit action before
Push/Pull/ReCommit/Create Tag for git-svn metadata. Its callback preserves the
Commit repository/access context through the native SVN workflow. Both-engine
private commit checks passed, including once-only selection and the existing
cancellation/cleanup cases. Actual SVN submission, receiving-window/scoped grant
acceptance and physical menus remain open; see the Commit audit.


Hosted run 38267892128 failed in the grouped comparison receiver after reference
folders passed. The Comparison/Fetch/Create Branch fixture audit corrected
incomplete PID publication and added bounded failure cleanup while retaining the
original assertions. All three focused families passed with both Git engines;
newer CI remains unverified. See the Reference Browser audit and scoped QA record.


SVN workflows now freeze retired presentation and own their prompt/cancellation
lifetimes. Scoped window checks retain the Commit repository/executable/lease
under a different busy workspace and cover options reuse/conflicting operations.
Final private native checks passed with both Git engines after correcting an
initial fixture URL-equality assertion. Actual SVN authentication, physical UI
and signed App Store acceptance remain open; see the SVN audit.


SVN progress now shares the native styled output/control family with Commit and
Merge: links, colored prefixes, completion metadata and original-icon copy menus.
Actual native log checks with both Git engines cover private clipboard behavior,
light/dark warning colors and error/Retry state, alongside the existing SVN
workflow checks. Physical/signed/public SVN acceptance remains open.


The Bugtraq Regex Tester now has a native editable sample, source-order Message
part/Bug-ID fields, C++ ECMAScript highlighting and OK/Cancel expression return.
File → Bugtraq Regex Tester opens the utility with current repository expressions
when available; it does not write configuration. Invalid edits retain the last
valid expressions for styling current text. Owned debounce/helper work is fenced
against editing/closure and counted for Quit. The dialog is a partial replacement;
the full Issue Tracker configuration page/parent Apply integration and plugin
providers remain open. See [the issue audit](ISSUE-TRACKER-PARITY.md).


Settings → Issue Tracker Config now ports the source scope selector, BugTraq
fields/inheritance/booleans, provider metadata and Save-to control. It owns the
Regex Tester; tester OK edits the page draft, shared Apply writes the selected
configuration and Cancel restores unsaved values. The original Bugtraq icon is
bundled with provenance. Focused Core and native checks passed; provider execution,
physical/signed acceptance and Windows association adaptation remain open. See
[Issue tracker audit](ISSUE-TRACKER-PARITY.md).


Reviewed compositor captures now document Issue Tracker Config and Regex Tester
in both themes on GitHub Pages and README. The page uses a dedicated native host
with shared footer, not the complete Settings navigation window. Source field/
group order was compared with the pinned screenshot/resource; full physical and
signed parity remain open. Visual review corrected repeated placeholders in empty fields and refreshed the
captures after a passing Debug build. Core/behavior suites were not rerun.

## Autotext Tester

The native content/regex/Scan/results/timing/Exit workflow and owned Settings
entry point are implemented. It uses the original C++ capture engine. Physical
and signed acceptance remain open. See [Autotext audit](AUTOTEXT-TESTER-PARITY.md).

## Client Hook Scripts

The native Hook Scripts list and configuration dialog retain source controls,
with the original hook icon, global/project persistence, shared Apply/Cancel and
per-user repository-script approval. Owned execution is connected to the six
Commit/Push/Rebase boundaries and non-wait scripts remain cancellable through
File. Focused Core/native checks pass; alternate routes, precise source edge
cases and visual/signed acceptance remain open. See
[Client Hooks audit](CLIENT-HOOKS-PARITY.md).


Clean now owns manual folder authorization and fresh Retry, refuses duplicate
options submissions and cancels retired progress workers while retaining their
Quit/grant lifetime. Debug and six grouped native cases passed. Automatic access
discovery, durable additional grants and physical/signed acceptance remain open.
See [Clean audit](CLEAN-PARITY.md).


Both comparison editors now expose saved Collapsed view, source-context folding,
marker expansion and reveal-before-navigation without rewriting editor text.
Three-pane result expansion uses exact engine anchors retained in edit/Undo
presentation. Debug, 39 focused Core checks and a grouped native folding/wrapping/
editor receiver passed. Physical, VoiceOver, large-document and signed acceptance
remain open. See [folding audit](MERGE-FOLDING-PARITY.md).


Native File/Open now checks Save/discard/Cancel and replaces two/three-pane
content in the same window, retaining its geometry and ownership. Scoped Open/
Reload menus, duplicate/Close/Quit guards, independent pending Save lifetime and
identity-safe cached callers accompany the replacement. Debug and grouped native
Open/editor regressions passed after a frame repair and fixture window-lifetime
repair. Patch mode still opens the separate native Review/Apply workflow;
physical/visual/signed acceptance remains open. See [Open audit](MERGE-OPEN-PARITY.md).


File/Open patch mode now prepares and checks Review/Apply before replacing the
same native editor window; invalid patches/cancellation retain the original.
Review/Apply can Open back into comparison with existing dirty Save handling.
Scoped menus, shared keyboard ownership and preparation Close/Quit guards cover
the round trip. First Debug and grouped native patch/Open checks passed; Core
was unchanged. Physical/signed/full-source acceptance remains open. See the
[Open patch follow-up](MERGE-OPEN-PARITY.md).


Three-pane Save As now offers left/right/result, with source row inclusion,
encoding and owned export handling. Compare either source with Base opens a
separate native comparison of private read-only stage snapshots. Debug, 16 Core
checks and grouped native source/editor checks passed; source path rebinding,
physical/visual/signed acceptance remain open. See
[source tools](MERGE-SOURCE-TOOLS-PARITY.md).


Create Patch Serial now uses source no-tag Browse References and entered-revision
single-selection Log pickers, captured folder/range ownership, cancellable initial
and unified reads, source count limits and private viewer preferences. The connected
options/progress/streaming family passed grouped system/bundled native checks and
30 affected Core cases (plus the changed no-tag case recheck). Physical and signed
acceptance remain open; see [Format Patch](FORMAT-PATCH-PARITY.md).


Request Pull now owns its Start Log/options and closes cancellable branch,
validation and generation processes before ordinary retirement. Forced closure
fences generated documents and retires mail options while preserving operation
accounting. Its source End/URL presets also flow through authorized macOS action
links into editable native inputs. See [Request Pull](REQUEST-PULL-PARITY.md) for
grouped evidence, command-link syntax and physical/signed acceptance limits.


SSH key file permissions now have a user-facing Saved Data manager alongside
saved passphrases: inspect paths without reading keys, authorize, copy and
confirmed selected/all forgetting with stale snapshots and owned native panels.
See [SSH identities](SSH-IDENTITY-PARITY.md). Core CI also skips the duplicate
SwiftPM UI-executable build through an opt-in manifest mode; full Xcode app/native
checks remain in the workflow. The package graphs retain identical Core tests,
resources, SMTP and revision utility targets. Hosted execution is still pending.


The hosted Merge Find timeout in `583a6534` was reproduced and repaired in its
fixture: unresolved aligned placeholder rows are now checked before selecting
both sides and exercising the original three-match Find/Replace/Undo assertions.
The isolated native phase passed; this is not a full hosted CI pass. See
[the repair record](qa/merge-find-ci-repair-2026-10-16.json).


The older hosted run at `78bcdd06` failed its small Settings footer containment
check after passing the build/Core and earlier native steps. The native page/footers
now reserve explicit control-frame space; the original assertion plus a stricter
margin check passes locally, with six refreshed light/dark captures. Hosted
verification remains pending. See [the scoped repair](SETTINGS-NAVIGATION-PARITY.md#native-footer-containment-after-hosted-failure--october-16-2026).
