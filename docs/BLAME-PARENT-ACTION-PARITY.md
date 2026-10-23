# Blame historical parent and origin-file actions

This connected partial review follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`, particularly
`TortoiseGitBlame/LogListBlameAction.cpp::{GetPaths,GetParentNumbers,GetParentHash,ContextMenuAction}`,
`TortoiseGitBlame/TortoiseGitBlameView.cpp::{OnRButtonUp,ContextMenuAction}`,
and `TortoiseProc/GitLogListBase.cpp::OnContextMenu`.
It supplements the earlier Blame menu and consumer-policy reviews; their parent
commands already existed and are not claimed as newly ported screens.

## Parent selection and exact file identity

Historical Log actions gather every attributed origin filename for the selected
commit, or the displayed path for complete-history-only commits. Source actions
use the pointed line's origin filename. Existing Core scans each real commit
parent, retains existing modified/renamed/type-changed files, excludes births,
deletions and submodules, and creates a comparison containing only that file.
A rename carries its old parent path and new destination path. Previous Blame
uses the old parent path/revision; source-line invocation also retains the
original source line and applied Blame options. Comparison/unified actions keep
the frozen parent/commit/file snapshot and alternate-tool routing.

One parent can provide multiple attributed origins. Their `Identifiable` keys
now include parent number, hash and exact UTF-8 old/new paths; they no longer
collapse to one parent hash. Source-path cache keys also preserve UTF-8 identity
instead of using Swift's canonically equivalent string equality. A comparison
from another repository, destination commit or unrelated old filename cannot be
submitted as a parent action for an otherwise valid target.

The embedded Log groups choices by actual parent number and dispatches every
relevant origin file in that group. Menu ordinals describe the filtered parent
list, while the payload retains the actual Git parent. Log parent labels now
use the captured parent subject, its pinned 20 UTF-16-unit truncation and short
hash. The source popup uses its simpler ordinal labels. Its Compare item and
first parent choice receive the source default-item emphasis when
`DiffByDoubleClickInLog` is enabled. Existing source artwork and private icon
preferences remain in use.

## Popup and operation ownership

A parent-read failure leaves the source popup's independent Log and clipboard
commands available, matching the Windows catch-and-continue behavior. It also
records the read failure. New requests retire old pending popup callbacks even
when the older request was for a cache miss and the newer request is cached.
The existing captured one-shot action policy remains: after a menu is shown,
its target stays the pointed source/commit rather than following later ordinary
selection changes. Reload, policy retirement, blocking children, Quit and owner
retirement still refuse actions as applicable.

Parent and patch reads retain access and their actual operation counter until
completion. A cancelled noncooperative reply cannot repaint targets, show a
late popup or create a viewer. Production unified dispatch carries the owned
cancellation token through external viewer launch and checks the original model
again before builtin presentation. Legacy injected unified callbacks remain
supported for existing private fixtures.

Builtin viewers are constructed with the parent's preferences, appearance and
alpha value before presentation. Containing-reference windows inherit the same
state before display. A containing picker or busy/sheet-owning viewer blocks
parent commands and normal close; change-only callbacks avoid repeated model
publication. A child's own picker can finish without self-locking its parent
availability predicate. Plain containing-reference reads remain cancellable
when their parent closes. Global Quit consumes exposed child/blocking state and
actual work counters through the parent integration.

## Validation scope and remaining differences

### Grouped workspace comparison delivery — October 23, 2026

The actual workspace route now accepts all origin-file snapshots from one parent
action together. Previously the model invoked the workspace once per origin;
the first invocation set its busy state and silently prevented later origins
from opening. This differs from `LogListBlameAction.cpp`'s comparison branch,
which dispatches every parent filename. The grouped request preserves each
snapshot's parent/commit endpoints, old rename path and destination path, in
captured order. It asks the existing multiple-diff confirmation once for the
complete file count and retains the initiating Shift tool choice, preferences,
repository grant and window appearance through preparation.

Blame owns the request token and operation count until the actual workspace
callback returns. Reload, document opening/replacement, Quit and closure cancel
pending delivery and reject stale results; an already accepted comparison window
keeps its independent workspace ownership. Source-pane comparisons use the same
route with their one-file snapshot. The old synchronous callback remains for
independent consumers, while production installs the owned aggregate callback.
See [connected history file delivery](HISTORY-FILE-DELIVERY-PARITY.md) for the
related workflows and grouped validation record. Implementation alone does not
establish a validation pass or complete Blame parity.

`GitBlameParentActionTests` covers distinct same-parent origin identities,
canonically equivalent name bytes, and a real three-parent merge whose first
parent is irrelevant, verifying filtered ordinal/subject labels against actual
parent contents. Existing focused Core cases cover renamed literal paths,
multiple origins, file births/deletions, two-parent merge contents and scoped
patches. `docs/qa/blame-parent-action-native-2026-10-18.swift` exercises real native
source menus, injected failure/supersession, old rename path/original line/options,
alternate comparison, foreign destination refusal, default emphasis/icons,
hidden inherited builtin/containing windows, a real nested renamed browser file
listing/selection handoff with one-shot initial-file consumption, child blocking and held read
retirement. The parent records grouped validation results; fixtures alone are
not proof of a pass or hosted CI success.

This family does not certify every Windows Blame menu, complete Blame visuals or
physical pointer/VoiceOver discovery. The source text popup retains the port's
existing unified-diff and native text-copy/select actions beyond the smaller
Windows popup. AppKit bold emphasis is the native adaptation of Windows default
menu items. Exact source libgit action-bit equivalence for type changes/copies,
all octopus/rename ambiguity cases, signed security-scope deployment and external
viewer application behavior remain outside this partial review. Parent-number
labels, command availability and cancellation do not imply that the entire port
is complete.

Actual grouped outcomes: [connected history/reference evidence](qa/history-reference-workflows-2026-10-18.json).
