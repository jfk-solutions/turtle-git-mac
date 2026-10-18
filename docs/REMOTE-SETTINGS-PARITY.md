# Manage Remotes

Reference: pinned `CSettingGitRemote` and `IDD_SETTINREMOTE`, upstream
`7338078f8ddd924b8cddee35f512f2286072136d`.

The native page now replaces the Push/Fetch remote form and is available from
Browse References remote folders with the original Settings icon. The source
list/field/button order, URL/Push URL, legacy key, tag combo, Push Default and
three-state Prune are mapped to native AppKit controls. Apply/OK/Cancel/Help adapt
the enclosing Windows property sheet. The port remains partial until native
identity transport and physical/signed acceptance are verified.

## Configuration behavior

`RemoteSettings` reads raw effective URL, Push URL, legacy PuTTY key file, tag
policy, native SSH key path, literal true/false/inherited Prune and byte-exact Push Default identity.
URL aliases are not expanded in the settings editor. Empty and unknown tag
policies map to reachable; nonliteral Prune values map to inherited, as upstream.

`RemoteSettingsFields` retains the source changed-mask values. Apply writes Push
Default first, then adds a remote when the name bit is set, then writes URL, key,
tags, Prune and Push URL in source order, then the native SSH key adaptation. A new remote uses its raw URL; subsequent
URL edits convert backslashes to slashes. Earlier successful writes remain after
a later failure. Only edited fields are written. Git's single-value config setter
does not replace all multivalued settings. Unset failures are followed by an
effective-value check so inherited or remaining values cannot silently appear
cleared. Unchecking Push Default does not clear a different remote's default.

Adding an existing name fails unless the caller explicitly removes the name bit
after obtaining overwrite consent. Rename and Remove use Git's own remote
commands, retaining Git's refspec/tracking updates. Slash-containing remote names
are supported. All operations own cancellation tokens, including calls which
omit a token, to preserve argument bytes through the native process runner.

The collision advisory checks local configuration and includes, the four source
remote/SVN refspec key families, byte-exact own-fetch exclusion, and the first
destination substring with an end-or-slash boundary. A collision is advisory,
not a hard validation gate. Exact libgit2 include/regex edge equivalence remains
unverified.

## Native behavior and remaining transport work

Rename is separate from Add New/Save. Native Save/Discard and overwrite/removal
questions use source messages; overwrite defaults to No. New remotes offer the
no-tags warning with a saved Yes/No suppression choice and a Fetch offer. The
Browse References page owns the resulting shared Fetch controller; Push/Fetch
embedded pages suppress that offer, matching the source default-page settings
route. URL entry in an empty list prefills origin. Field edits retain a source
changed mask, and failed saves during a dirty selection change still report the
error and proceed to the selected remote, as source selection handling does.

All Git reads/writes, collision checks, rename/removal and reference reloads are
owned and fenced against close and late confirmation callbacks. Parent close and
Quit are blocked during busy requests/attached children. Closing a page forcibly
cancels its requests. Cancel discards unsaved fields; earlier Apply/Save operations
remain. Errors appear in the native footer; the key tooltip identifies the Windows
interop limitation. Sync URL cleanup and the timed native origin hint are covered by the October 14
batch below. The complete enclosing Settings tree and transport acceptance remain
partial.

`puttyKeyFile` preserves Windows configuration for interoperability only. A
separate native SSH Key row selects a file and remembers a private read-only
bookmark. Typed paths do not authorize key access. The native setting preserves
Windows paths rather than interpreting `.ppk` as OpenSSH. See
[identity selection](SSH-IDENTITY-PARITY.md). A global SSH command cannot implement
multiple identities for Fetch All; source loads keys into Pageant. The private
[agent primitive](SSH-AGENT-PARITY.md) is wired into the captured native transport workflow; public/signed authentication
acceptance remains separate.

Physical layout, light/dark, keyboard, accessibility, signed Finder/App Store,
authentication, live forced-process cancellation timing and broad config races
remain unverified. Backend tests are not evidence of a completed dialog.


## Connected manager return/history/hint batch — October 14, 2026

Successful Rename and Remove now prune their exact old remote name from this
repository's Synchronization URL history, matching CleanupSyncRemotes and
HistoryCombo::RemoveEntryFromHistory. Other repositories, different UTF-16 names,
URLs and list order remain. A declined or failed mutation cannot prune history.
Sync's existing manager-dismissal refresh therefore sees the cleaned list while
retaining typed URLs, branch fields and source selection semantics.

Push's embedded manager now refreshes its remote/reference catalog and branch
classification on return. A deleted selected named remote falls back to the
current source's configured remote or the first remaining name. Arbitrary URL,
typed destination, force/tags/submodule/push-option and other operation choices
are retained. All-remotes clears when fewer than two names remain. This refresh
uses the owned preparation/cancel/Retry/retirement/Quit path; Retry repeats catalog
refresh rather than resetting the draft through source/default loading. Fetch and
Pull retain their existing own default read after adopting the manager's catalog.

An empty remote list schedules the source's one-second origin hint. The native
URL-anchored transient popover uses the original text. Editing name/URL, loading
nonempty names or retiring the page cancels it. The existing URL-to-origin autofill
remains. Collision advisory reads now retain independent operation/Quit accounting
through cancellation and forced retirement, including superseded reads.

The Debug build and six grouped native cases passed across system/bundled Git
after a gated-fixture argv matcher correction. No app build or Core check was
repeated for that fixture repair; all receivers were reaped. See
[batch evidence](qa/remote-management-family-2026-10-14.json). Complete physical popover/focus/keyboard/
VoiceOver, source layout, live transport and signed/App Store acceptance remain
open. Source rename/remove and the native catalog adaptation are not an atomic
transaction against concurrent external configuration writers.


## Native Remote name list and selection — October 18, 2026

The pinned `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINREMOTE` uses a bordered,
vertically scrolling, single-selection `IDC_LIST_REMOTE` beside its editable
remote fields. Its `SettingsGitRemote.png` reference shows a continuous list
viewport with a clear selected name, not loose text embedded in the form.
`CSettingGitRemote::OnLbnSelchangeListRemote` retains Save/Discard handling before
loading the newly selected remote. No initial remote is automatically selected.

The native list now has a bezel border and explicit full-height viewport beside
the form, alternating native row backgrounds and regular selected-row painting.
Its name column and native horizontal scrollbar accommodate long remote names;
name-cell tooltips retain the full literal name. An empty viewport says “No
remotes configured.” This noninteractive guidance is a macOS adaptation of the
source's empty list. Both standalone and shared Settings forms retain the same
single-column list, source field/button order, native light/dark colors and
existing SSH-key adaptation. Tab follows the list into the Remote/Rename/URL
controls; ordinary list arrows retain native selection and focus behavior.

Rendering now reloads actual native rows only when the remote-name catalog changes.
Typing a field no longer rebuilds the list or resets its scroll position. Catalog
updates preserve the top visible name when possible, while a newly selected or
renamed remote scrolls into view. During the owned asynchronous Save/Discard and
remote read, the requested row stays highlighted while fields and other list
changes are disabled. Accepted selection still belongs to the original model/read
request. Invalidated, child-owned, busy and attached-sheet lists reject later
selection callbacks. Raw field updates compare UTF-8 bytes so canonical-equivalent
spellings do not leave the wrong displayed name after an accepted read.

Add New/Save, Rename, Remove, Fetch offers, actual Git configuration and the shared
Settings transaction remain the same workflow. The list does not introduce a
second draft or a separate configuration writer. Cancel/OK acceptance for the
shared Settings frame remains covered by that frame's own receiver.

`qa/remote-list-native-2026-10-18.swift` exercises the shipping list's actual
bounds, native arrow selection/field read, Tab links, row reuse/scroll through
field edits, a held Save/Discard reply and busy refusal, real Add/Save/Fetch/
Rename/Remove controls, owner retirement and unchanged HEAD/index/input bytes.
It checks both standalone minimum-size and embedded Settings content. Optional
`TURTLEGIT_REMOTE_LIST_CAPTURE` writes owned invisible-window content renders in
Aqua and Dark Aqua for individual visual review. The parent records actual results;
fixture existence is not a pass. Physical mouse/key gestures, VoiceOver, all
localizations/resize extremes, signed grants and full Settings parity remain open.

The focused user-report checkpoint also retains list keyboard focus through the
owned selection read: disabling NSTableView had displaced it to NSWindow. Restore
only that original window/table focus after drain; another field or sheet is not
overridden and no background window is activated. New and retained Remote
workflows pass with system and bundled Git.

[Actual grouped evidence](qa/history-actions-2026-10-18.json) preserves the initial
constraint-ordering exception, keyboard-focus diagnosis, affected repairs and
receiver cleanup. The four optional content-cache renders show list geometry but
lose backdrop and button layers, so they are not published as complete window
screenshots. Physical/compositor visual acceptance remains open.
