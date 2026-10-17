# Finder command handoffs — implementation in progress

Reference: pinned MenuInfo.cpp, ContextMenu.cpp, PrevDiffCommand.cpp,
BlameCommand.cpp, LogCommand.cpp, Git.h's SetCurrentDir and the native port
at 7338078f8ddd924b8cddee35f512f2286072136d.

The Finder command projection now includes eight additional source entries:
Sync, Diff with previous version, Show log of this folder, Blame, Edit conflicts,
Settings, Help and About. Their source conditions and group positions are retained
in the existing independent condition/order fixtures. Their original colored
icons are used; Sync uses the source menurelocate icon. These entries are enabled
in both Context Menu settings catalogs. Eight catalog groups remain unavailable:
four SVN commands, Daemon, LFS, Review Patch and Send Mail. This checkpoint does
not establish complete source command or dialog parity.

Sync launches the existing native Synchronization window, retaining its remote/
branch/options/history/rebase handoffs. Its source menu clauses exclude merge and
bisect sessions. Blame opens the existing native Blame viewer for the selected
file at HEAD with the saved detection/preferences. Added paths and directories
are excluded by source clauses. Edit conflicts opens the existing native text/
image/submodule conflict dispatcher. As in the source singular path command, the
first selected path is edited; the original request still captures every path,
and repository authorization/revalidation precedes dispatch. Folder selections
are excluded, and cached conflict eligibility is checked.

Previous-version Diff ports PrevDiffCommand's distinction: directories compare
HEAD~1 with the working tree, while files compare the second history entry for
that path with the working tree. It is not a generic HEAD~1 file comparison.
The file history query is literal and bounded to two entries, with an explicit
no-previous-revision result. File comparisons retain current working bytes rather
than stopping at indexed content. Directory comparisons open Changed Files with
immutable scope; subsequent revision/option reloads keep that scope. Scope also
belongs to comparison-window reuse identity and the Core snapshot, so an all-file
patch request cannot accidentally include a similarly named sibling directory.
Regular unscoped comparison callers retain their existing behavior.

The normal submodule-root Log remains the child's own history. The separate
Show log of this folder source entry uses the parent's gitlink history, matching
SetCurrentDir's submodule flag. Cached parent metadata contributes an authorization
target, but Core independently verifies the registered parent and index ownership
before choosing it. An unregistered nested repository is rejected by this special
route. The native Log receives the literal relative gitlink path; multi-repository
selection and sandbox-root boundaries keep their existing preflight gates.

Settings, Help and About are application utilities rather than Git operations.
Their URLs accept an empty selection and never synthesize Git argv. Help, About
and global/outside-repository Settings bypass repository authorization and
background status-read busy state. Finder Settings inside a known repository
uses that selection’s repository, going through ordinary authorization/adoption
when it differs from the current repository. Global Settings explicitly disables
local Git/project/credential sources and Remote, even if the app has another
repository open. An existing modified/busy Settings context is retained rather
than silently switching it; the user is directed to finish that window first. Quit confirmation
still suppresses dispatch. Finder visibility/Shift/path exclusions continue to
apply before URL capture. Utilities work outside repositories and in bare-root
menus, while retaining the existing visibility policy. Help opens the project's documentation website; About uses the native
macOS panel with fork/license/artwork credits and a source link.

App-menu Settings and Finder Settings now share one native property-sheet owner,
using the existing SettingsNavigationController and shared transactions. Cmd-comma
and repeated Finder requests focus that window. Closing invalidates page drafts,
child state and subscriptions; reopening creates a fresh navigation/cache/
transaction. The existing close/save/child guards remain in the delegate proxy.
Repository changes update the open navigation through an owned workspace
subscription. This removes reliance on private SwiftUI Settings-window selectors.

Grouped validation: the Debug arm64 native build exited 0 with 44 warnings
and no exit-zero/no-output diagnostics. 46 focused Core tests passed, zero
failures, in 11.297 seconds. These cover the 53 pinned conditions, path-history
and HEAD~1 semantics, working/index/HEAD preservation, literal scoped file and
patch results, invalid/history/cancellation cases, parent gitlink discovery and
existing comparison/request/catalog/icon regressions. The actual Finder menu
builder receiver exited 0, including all 53 projected commands and new utility/
Sync/conflict entries. The existing Context Menu draft/transaction receiver also
exited 0 and rendered four updated page previews, all inspected. No installed
app or Finder extension was launched; no full suite was rerun. This receiver
does not verify the new full Settings owner’s native handoff or context gates.
See qa/finder-command-handoffs-2026-10-12.json. Physical Finder click/Shift delivery, initial cold-launch ordering,
Settings window focus/reuse/close/reopen, native Blame/Sync/editor handoffs,
comparison option/revision reload gestures and signed App Store execution remain
separate acceptance. Compilation and isolated Core/builder checks cannot certify
these full workflows or the entire port.


## Captured Finder comparison-tool choice — October 15, 2026

The extension captures Shift when a menu command is activated and sends an
explicit default/alternate comparison-tool field in its immutable URL request.
The containing app applies that choice for the complete initial handoff,
including repository discovery, modal permission selection and child comparison
preparation. It ends after that invocation and does not become a setting for later
independent UI commands. Diff, previous-version Diff, marked-file comparison,
two-file comparison and conflict editing therefore receive the Finder choice
rather than depending on the key state when the app later processes the request.

The optional `alternate=0`/`alternate=1` field preserves an explicit default even
when another invocation has Shift set. Existing links without the field retain
the prior app-side capture behavior. Duplicate, missing and malformed values are
rejected before dispatch. The field carries no sandbox permission. Literal paths,
source-file packets, selection snapshots and command eligibility remain in their
existing validation path. Control on Mark for comparison still creates Clear
comparison mark; its unused tool field is omitted.

Marked/two-file viewers also use the owning comparison preferences, matching
repository file-comparison preparation. Native verification uses private tool
preferences and intercepted presentation, without launching third-party apps.
The [batch record](qa/finder-tool-handoff-2026-10-15.json) distinguishes packet,
actual builder and delayed repository-adoption checks from physical Finder
activation, live permission gestures and signed App Store acceptance.

All 55 current source catalog groups now have Finder routes. Earlier unavailable-
group counts in the historical command/LFS/settings checkpoints predate SVN,
Daemon and patch routes. This describes routing availability, not full shell
eligibility, native appearance or end-to-end command certification. Finder drag-
destination menus and signed activation remain open.


## Installed Finder transport — October 17, 2026

The signed installed extension now retains immutable command requests locally and
assigns each menu leaf a primitive numeric tag. The actual Finder callback kept
that tag but dropped `representedObject`; this previously made commands return
without opening a window. A tag can be claimed once, and a new menu invalidates
the previous projection. The existing captured paths, modifiers and URL validation
remain in force. The extension explicitly opens its own containing app rather than
depending on whichever development build owns the URL scheme.

On macOS 27.0.1, selecting **Zeige Log** for the disposable README from the real
Finder context menu opened the installed Apple Development signed app's file-scoped
Log window, including its graph/list and unchecked Show Whole Project control.
The callback log confirmed `represented payload present: false`. The source-built
menu receiver also covers tag-only callbacks, repeated/stale dispatch and app
bundle validation. See [installed QA](qa/finder-installed-2026-10-17.json). This
closes that observed transport failure, not acceptance of every command, cold
launch, modifier gesture or multi-selection case. Earlier pending-activation
statements describe their respective historical checkpoints.
