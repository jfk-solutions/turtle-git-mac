# Git configuration page — implementation in progress

Pinned reference: `7338078f8ddd924b8cddee35f512f2286072136d`,
`SettingGitConfig.cpp`, `GitSettings.h` and `IDD_SETTINGIT_CONFIG`.

The Settings → Git page now implements the source selector (Effective, Local,
Global, System), User Info (Name, Email and Signing key ID with individual inherit
checkboxes), AutoCrLf/SafeCrLf choices, three-state QuotePath/Prune checkboxes and
separate Local/Global Save to selection. Effective values are read-only. Local
is unavailable when no repository is open. System values can be copied to a
Local/Global destination; the source page does not offer system as a save target.

The repository layer reads scoped Git configuration with includes, preserving
empty versus absent identity values. Effective identity follows upstream's
GIT_AUTHOR_NAME/GIT_AUTHOR_EMAIL, author.name/author.email, then user.name/email
precedence. Effective missing QuotePath defaults to true and Prune to false;
scoped absence is mixed/inherited. Git normalizes boolean aliases. The special
input/warn line-ending values remain distinct. This page does not honor
.tgitconfig for these seven fields, matching InitGitSettings(false).

When effective Name and Email are both empty on initial load, the page selects
Global, clears their inherit flags and selects Global as the save destination.
Switching sources reloads/discards drafts as upstream does. Selecting Local or
Global also selects that save target. Apply to a different source/destination
asks Save/Abort with Abort as the default. Apply writes the seven source fields
in source order; failure stops remaining writes and reports that earlier values
may already have been saved. Empty line-ending and mixed/inherit controls unset
the destination entry; explicitly empty non-inherited identity remains empty.
Repeated entries are replaced/removed by the CLI adapter rather than relying on
libgit2's multivariable write behavior; cross-engine compatibility needs review.

View effective config displays selectable read-only text with Git's origin
annotations. View systemwide gitconfig displays the actual file content. Both
can open a read-only temporary copy in the configured alternative editor. Reads use owned cancellation, and switching
repository/source or leaving the page rejects stale results. Loading failures
keep Apply disabled. Saving retains its repository permission grant and completes
its source-ordered batch after owner closure; Quit remains blocked until it ends.
Repository-scoped access is checked in AppStore builds. Global paths follow the Git runtime environment, including the app's sandbox
home. External files can obtain remembered directory grants through owned native
folder panels; grants are restored at app startup and remain active for other Git
operations. Symlinks are checked against canonical grant containment. Folder
permissions include adjacent lock-file creation. A separate AppStore folder
selector also allows recovery when an inaccessible config prevents path discovery.
Permission support is implemented but not yet verified in a signed sandbox.

## Config editors and permissions continuation

The source's local/global/XDG/system edit buttons and .tgitconfig action are now
implemented through the configured alternative editor. Missing files are created
without overwriting a concurrently created file. Bare-repository .tgitconfig
uses an exact HEAD blob copied to a read-only temporary file retained until app
termination. XDG editing appears when its directory exists. Config paths use Git
var, including runtime relocation/environment overrides; older engines have
conventional-path fallback. System editing uses ordinary macOS editor permissions,
with no elevated helper. See the [Git var reference](https://git-scm.com/docs/git-var).
The source hierarchy hint uses an owned native sheet with a saved suppression
checkbox. Read-only copies are removed at application termination.

## Remaining acceptance work

- Signed global/config-file permission and persisted-grant execution,
  included-file write compatibility and external configuration changes.
- Native acceptance of the implemented shared Apply/Cancel, displayed hint/editor and
  platform comparison for system edits requiring administrator access.
- Real repository/environment/inheritance/write/error checks across Git engines,
  native scope switching, three-state input, confirmation, close/quit ownership,
  keyboard/focus, light/dark screenshots and displayed acceptance.

The combined Debug build passes. Three focused real-Git tests cover local writes,
include precedence/clearing, repeated-value replacement, boolean normalization,
invalid destinations/values and cancellation without writes. They pass with zero
failures. Native scope/editor/sheet and signed sandbox acceptance remain open;
see `docs/qa/settings-history-batch-2026-10-11.json`. No dialog is newly certified
and inventory counts are unchanged.

The native tree now hosts this page and conditional Remote. See
[Settings navigation](SETTINGS-NAVIGATION-PARITY.md) for implemented shared draft handling
and remaining acceptance scope.


The [hierarchical settings lifecycle batch](CONFIGURATION-LIFECYCLE-PARITY.md)
adds shared read/Quit ownership, Dialogs 3 save ownership, captured confirmation
context and owning hierarchy-hint preferences. Its
[grouped checkpoint](qa/configuration-lifecycle-2026-10-15.json) records native
checks and the remaining physical/signed scope.

## Coherent source forms and owning editors — October 17, 2026

Loading a level now collects its configuration origins and required values before
publishing the accepted source, save destination, draft and baseline together.
The pending level has a loading caption. Failed/cancelled reads retain the prior
accepted display and leave editing/Apply disabled until a successful read. File
editor actions also require a loaded context, preventing an old origin from being
edited after a new repository failed to load. A different repository clears the
old context before loading. Switching source still discards drafts on success,
matching the source level-selection behavior. Initial empty-identity defaults and
the hierarchy hint are consumed only after a successful load, so retrying a failed
first Effective read still selects editable Global identity fields.

The source row now includes its `|`/`<<` hierarchy indicators and native radios.
QuotePath/Prune retain three states with bounded native checkbox rows. Observable
page activity re-enables cached forms after returning. Accepted editor identities
fence old field/picker callbacks, and dismantled checkbox targets detach. The
source page's static control family now has explicit partial mappings; native
inheritance/layout and complete source certification remain separate evidence.

Before an authorized write starts, Apply rechecks the captured draft, source and
destination after confirmation and folder permission. A changed draft remains
unsaved with an explicit message. Once a source-ordered write has started, its
existing independent save/grant drain policy remains; later retirement does not
claim rollback. Hidden cached pages still participate in shared Apply/Cancel. An activation identity
prevents a hidden Apply completion from marking an explicitly returned page inactive.

Config files and displayed read-only text now open with their Settings owner's
Alternative Editor preferences. Replies are fenced by the request generation and,
for a displayed copy, its exact text. A retired editor cannot report an error on
a new level or replacement display. The explicit configuration-folder recovery
chooser now has an independent Quit/Settings lifetime and retires on deactivation.

Four distinct native case/engine combinations pass with system and bundled Git; the two affected source cases pass again after visual layout repairs and the recorded fixture correction. Both raw light/dark page captures were individually reviewed, including full-width CrLf and three editor columns. All eight owned receivers were reaped and independently absent. Core was unchanged and not repeated. See [batch evidence](qa/git-config-source-family-2026-10-17.json) for build diagnostics, fixture failures, intercepted editor scope and open physical/signed acceptance.
Live editor delivery, physical keyboard/sheets, signed configuration grants,
system elevation adaptation and complete source/App Store acceptance remain open.

## Exact scoped project values — October 17, 2026

The shared Project Dialog/Issue Tracker/client-hook writer passes the command-only
`-c core.precomposeUnicode=false` override. Git on macOS otherwise precomposes
Unicode argv, including text values unrelated to filesystem spelling. Exact
submitted UTF-8 now reaches Local, Project and Global stores; the repository's
persistent preference is retained. The 12 focused configuration/issue/hook checks
and two-engine native consumer checks are recorded in
[the connected Issue Tracker batch](qa/issue-tracker-source-family-2026-10-17.json).
This is scoped writer behavior, not a global change to Git path policy.


## Identity and captured drafts — October 19, 2026

The [connected exact-text settings family](SETTINGS-EXACT-TEXT-PARITY.md)
addresses canonical-Unicode aliases in edited values, captured save guards and
Git config arguments. Its dated record separates grouped checks from remaining
physical, signed and full-source acceptance. Existing source write order,
permissions and partial-failure behavior remain in effect.
