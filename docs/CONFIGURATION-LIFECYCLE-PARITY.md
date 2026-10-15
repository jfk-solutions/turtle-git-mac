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
locale enumeration. The four literal hierarchy separators (`|`, `<<`) have no
literal native equivalent and stay pending in the control ledger. The hidden
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
