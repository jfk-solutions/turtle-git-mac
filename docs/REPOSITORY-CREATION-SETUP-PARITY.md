# Repository creation navigation and result setup

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This continuation reviews `IDD_CLONE`, `IDD_CREATEREPO`, `CloneDlg.cpp`,
`CreateRepoDlg.cpp`, `Commands/CloneCommand.cpp`,
`Commands/CreateRepositoryCommand.cpp`, `AppUtils::SetupBareRepoIcon`,
`CCommonAppUtils::ExploreTo` and `CMenuButton::SetCurrentEntry`.
It extends [Clone](CLONE-PARITY.md), [Clone completion](CLONE-COMPLETION-PARITY.md)
and [Create Repository](INIT-PARITY.md); it does not certify those whole families.

## Source navigation and native form

Clone's source split button lists Browse then Open, remembers source `CloneBrowse`
and repeats the selected action from its primary segment. Both menu items use
source command artwork under native menu icon preferences. Selecting an action
persists it immediately, separately from accepted clone histories. Each dropdown
selection consumes a captured owner/form/draft receipt; editing, busy work, Quit,
closure and retirement reject stale callbacks.

Browse uses the owned native folder panel. Open trims the source and reports empty
or invalid input. Absolute paths and local file URLs reveal in Finder; relative
paths resolve against Clone's execution directory. Missing paths reveal their
closest existing ancestor. Failed reveal falls back to opening the original source,
matching ExploreTo followed by ShellExecute. Remote URLs use the registered macOS
application. Workspace refusal is an error in the form. Source opening does not
execute Git or create a destination. Local authorization and asynchronous work
retain their access and owner until drained; Cancel and Quit reject late results.

The native Form menu provides Command-Option shortcuts for source/destination,
source Browse/Open, key and SVN controls, Depth, Branch and Origin. Source Option
mnemonics are retained outside text editing; ordinary text entry keeps Option input.
The common router scopes commands to the current window and rejects retired menus.
Source option tooltips explain shallow, recursive, bare, no-checkout, branch and
origin settings. The form has a 780 by 480 content floor and permits vertical
resizing. Editable history and reference fields resist long-value window expansion;
full history values remain available through their tooltips. Create Repository
retains a compact 600 by 190 content area; its hosting view cannot expand the
confirmation into a tall spacer window.

## Bare repository decoration

Upstream SetupBareRepoIcon runs after Git success for bare Init and Clone, preserves
Desktop.ini and otherwise writes Windows folder-icon files. The macOS adaptation
uses NSWorkspace custom folder icons with the existing TurtleGit artwork including
Git text. It writes no Windows metadata. Existing Icon resource files, Finder
custom-icon flags and Desktop.ini preserve prior customization.

Init and both direct/progress Clone routes first discover the actual repository
kind. Only a verified bare repository at the captured destination is eligible.
The helper checks the captured access and destination directory identity before
mutation, retains permission through the real operation and shares a per-folder
receipt so inspection retries do not repeat icon writes. A replaced destination,
missing artwork, denied metadata or rejected native icon produces a warning.

Optional setup is awaited within the existing operation ownership. Cancel before
mutation prevents the decoration; closing an owner still drains its helper and
access. Once Git and repository inspection have succeeded, icon failure or
cancellation during optional setup does not change that successful Git result into
a failed Init/Clone. Init includes the warning in its success acknowledgment;
Clone retains it in its completed result, output and workspace handoff. Warning
results remain available for review rather than automatically closing.

## Validation and remaining work

The [dated checkpoint](qa/clone-create-source-2026-10-21.json) records actual
attempts, fixture corrections and the grouped native results. Core Git behavior
is unchanged by this family and no Core suite was rerun.

The optional `--only accessibility` probe retains exact shallow/bare help assertions.
It currently fails in this offscreen receiver: the public hosting-view hierarchy
exposes AppKit peers but no SwiftUI virtual controls. Direct protocol inspection
also exposed an SDK navigation-array type mismatch; the probe now uses the public
Objective-C getter for that array. No private accessibility activation flags are
used. This probe is separate from the default navigation/form/result/ownership
checkpoint; its failure is retained and tooltip/VoiceOver acceptance is unproven.
The default form case verifies actual field bounds, native keyboard routing,
stale bindings and compact Init geometry, and captures both appearances.

Physical picker/keyboard/VoiceOver behavior, actual registered remote protocols,
sandbox permission renewal, Finder icon persistence on deployment file systems,
signed/minimum-version execution, full source layout/state coverage and complete
hosted integration remain open. This family does not replace Finder Sync badges
or prove App Store distribution readiness.
