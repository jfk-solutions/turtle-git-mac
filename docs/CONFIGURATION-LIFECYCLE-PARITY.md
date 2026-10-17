# Hierarchical settings operation ownership

Git, Dialogs 3 and Issue Tracker settings retain their existing source selectors,
inherit choices, Save to destinations and source-ordered Git configuration writes.
This batch completes the shared native operation lifetime around those controls.

Configuration discovery and reads now remain counted until their tasks settle,
including after leaving a page or closing its owner. Git's View and Edit
configuration preparations share that ownership. Cancelling or superseding a read
cancels its Git token and prevents its late values or errors from reaching the
retired page. Quit waits for the owned task to settle even after its window has
closed. Captured access grants survive all exit paths.

Dialogs 3 now counts its saves alongside Git and Issue Tracker saves. Cached,
inactive pages can still participate in property-sheet Apply. Save confirmation
uses the captured source/destination; accepted writes keep their captured draft
and destination even if the page later retires. A late unaccepted confirmation
cannot start a save. Once a source-ordered write has started, it may finish after
forced closure; its result cannot reactivate or overwrite the retired page.
Configuration writes remain individually locked Git operations, not an atomic
transaction across all fields. Earlier fields may be saved before a failure.

The hierarchy hint in Git and Dialogs 3 now reads/writes the owning Settings
preference store. Suppression in a private Settings context no longer changes the
standard app preferences. Native permission and confirmation sheets retain their
existing dismissal behavior.

## Source comparison and control mapping

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
`GitSettings.h` supplies source/destination choices, hierarchy, and the
Save/Abort mismatch warning. `SettingGitConfig.cpp`, `SetDialogs3.cpp` and
`SettingsBugtraqConfig.cpp` supply the scoped fields and ordered save behavior.
Windows property sheets perform synchronous writes. Task cancellation, retained
security-scope leases and Quit ownership are macOS adaptations around that behavior.

The visible controls of `IDD_SETTINGSDIALOGS3` map to the native source radio
picker, Commit language/Limit/Border/Signed-Off-By controls, icon field/Browse/
inherit and Save to picker. Native CoreFoundation locale choices replace Windows
locale enumeration. The four literal hierarchy separators (`|`, `<<`) initially had no native
equivalent; the October 17 continuation below maps their meaning to an explicit
native hierarchy hint, without claiming identical geometry. The hidden
`IDC_KEEPFILELISTSENGLISH` combo and its hidden label are unused by the pinned
C++ page and remain explicitly unmapped. No extra checkbox is introduced.
Visible mappings remain partial: a model check does not prove full visual parity.

## Grouped checkpoint

The Debug build passed. Core configuration serialization is unchanged and was
not rerun. One grouped native fixture passed with system and bundled Git. It
holds each page's read across cancellation, verifies Quit ownership and rejects
late publication; holds each page's real local save across retirement; checks
captured values/destinations, cached Apply, late confirmation refusal and exact
HEAD/index preservation. Native Git/Dialogs 3 hierarchy suppression sheets write
only the private preference store. Both receivers were reaped and checked absent.
See [exact evidence](qa/configuration-lifecycle-2026-10-15.json).

The fixture injects held discovery/write boundaries and file authorization; real
local writes still use the production Git configuration adapter. Physical folder
permission gestures, signed sandbox grants, every source/error/partial-write
interleaving, full control geometry and complete application parity remain open.

## Hosted Unified Diff timeout investigation

An older hosted run passed 1,467 Core cases (two skipped), then timed out in the
bundled-Git native Unified Diff document case. Its same affected case passed
locally against the current Debug app at `b5ecda0b`; no production workaround or
longer timeout was introduced. Wait failures now identify the fixture source line
so a future hosted failure can identify the stalled condition. The hosted timeout
remains unresolved; the local pass does not establish hosted success.


## Project dialog source forms — October 17, 2026

Dialogs 3 now captures each field, inheritance toggle, language/sign-off picker,
source selection, Save to selection and icon Browse action with its owner, source
and form generation. Source reloads, busy operations, inheritance changes, chooser
roundtrips, cancellation and suspension retire the rendered callbacks. Cached
pages can still participate in Apply; accepted source-ordered writes retain their
captured values until settlement and do not publish after owner closure.

The icon chooser opens in the current icon’s folder and displays its relative or
absolute path in the native sheet message. NSOpenPanel does not use the inherited
Save-panel filename property, as documented in the AppKit SDK. Its result
is accepted once, only for the same active owner/source and exact original icon
draft. Repository-relative paths stay relative; external paths stay absolute.
A delayed result cannot overwrite a newer icon or persist an obsolete bookmark.
The native sheet is dismissed on suspension/cancellation/close. Exact UTF-8 icon
spellings also participate in modified-state and property-sheet notification;
canonically equivalent spellings are no longer silently treated as unchanged.

The source Config source / Commit / Dialogs / Save to order remains visible in a
scrollable native page. An explicit hierarchy hint explains the source separators.
Bare repositories retain their read-only HEAD project-config source and cannot
save into a worktree project file; Local/Global remain valid destinations.
Global-only settings cannot select repository sources/destinations. Language
validation accepts auto, disable, decimal and hexadecimal DWORD locale values;
out-of-range/invalid values and NUL icon paths fail before saving. Hidden, unused
file-list-English controls remain unmapped. The four separators are represented
by the native explanatory hint, while complete source geometry remains partial.

Core serialization is unchanged and its suite was not repeated. The Debug build
and the grouped native source family passed with system and bundled Git. The first
fixture assumed the Save-panel filename property applied to Open panels; the SDK
marks it unused. A focused repair now displays the current icon in the native
message and verifies its folder and cancellation, while injected replies cover
acceptance and stale/duplicate results. Two raw light/dark captures were reviewed.
All four receivers were reaped and independently checked absent. Exact attempts,
coverage and limits are recorded in [the checkpoint](qa/project-dialog-source-family-2026-10-17.json).
Physical chooser selection, signed bookmark grants and complete keyboard/VoiceOver/
small-window/visual acceptance remain open. No dialog is certified complete.
