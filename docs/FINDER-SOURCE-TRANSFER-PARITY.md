# Finder selected-file transfers

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
The active Explorer drop commands are in `TortoiseShell/ContextMenu.cpp:772–797`:
Move here, Move and rename here for one eligible source, and Copy and add here
when Move is unavailable. Ordinary Copy/Copy-and-rename/Export drop entries are
commented out in this source. `Commands/DropMoveCommand.cpp` supplies the rename
question, ordered Git move and error continuation; `DropCopyAddCommand.cpp` copies
before running Add. Existing native Move/Copy workflows implement those operations.

## Direct selection and destination review

Finder's selected-item menu now offers **Transfer…** with original command artwork.
It captures the exact selected file URLs immediately; the later clipboard and Finder
selection cannot redirect it. It honors the macOS file-transfer preference, icon
preference, existing shell restrictions and cached repository exclusions. Toolbar,
container and sidebar entries do not invent an item-source selection. Snapshot
eligibility performs no Git work inside Finder.

The source request uses `.transferFiles`, selected paths and no `sources` payload.
The containing app owns a native destination-repository picker. Cancellation
performs no Git mutation. Acceptance uses the existing repository/metadata/security
scope adoption path, then opens a native Transfer files review with captured
sources, destination, owner and preferences. The reviewed destination form has one
destination path and explicit source URLs. Neither form conveys sandbox authority.
The source picker requests a destination repository root; the review's folder picker
can select a subfolder of that captured working tree.

The review preserves source choice eligibility: one versioned source in the same
working tree offers Move and Move/Rename; multiple eligible sources offer Move;
unversioned/external sources offer Copy/Add. Administrative/invalid destinations
cannot enable any operation. It revalidates recently used destinations before use,
keeps twelve recent paths per repository and stores them in the captured preferences.
The destination list does not substitute a permission grant.

Accepted actions capture their ordered sources and folder before closing. The
chooser waits for actual native picker/owner-sheet detach and preparation drain
before delivering exactly one handoff. Move/Rename preserves separately staged
and working contents; Copy/Add retains the source and stages copied destination
bytes. Existing collision, rename, Ignore/Abort, source-grant and cancellation
workflows remain available. Quit confirmation blocks new operations in all three
windows. Retired asynchronous preparation and release receipts remain counted
until their workers and native sheets actually finish. Owner closure suppresses
late acceptance. Native children inherit appearance and hidden test-owner alpha.

## macOS adaptation and explicit remaining scope

This is an explicit selected-item workflow, not an Explorer right-drag interception.
Apple's public [Finder Sync extension API](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)
provides selected-item/container/sidebar/toolbar menus and badges for monitored
folders. It does not expose an Explorer-style drag-destination menu callback.
Physical Finder drag/drop interception remains absent; the app's existing drop
review and explicit source/destination workflows supply related functionality.
Availability outside monitored folders follows Finder Sync's platform restrictions.

Source fidelity remains partial: external/nonversioned macOS files are copied and
added after explicit destination/source permission checks; no Windows shell drag
modifier state is invented. Source-commented Copy/Copy-and-rename/Export commands
remain omitted. Full physical Finder/keyboard/VoiceOver gestures, multi-display
picker behavior, signed App Group/security-scope delivery and installed App Store
acceptance remain open. No whole-dialog/application completion is claimed.

## Grouped verification

`scripts/test-finder-source-transfers.py` compiles one stable cached receiver from
the actual app objects, actual Finder menu source and all five fixtures. The new
`FinderSourceTransferVerification` uses private repositories, preferences,
pasteboard and action logs, hidden owners/pickers, actual Move/Rename/Copy/Add Git
mutations, cancellation, recent-path revalidation and retained preparation/Quit
checks. Retained drop, Move, Copy and Finder transfer cases preserve their behavioral
assertions; affected drop handoffs now wait for actual asynchronous detach, and
sheet parents remain hidden; the receiver also hides every ordered native window.
Git global/XDG configuration and author/committer environment are isolated per case. Cache inputs include app objects/sources, framework
modules/binaries, receiver sources, architecture, compiler/SDK and flags through
`native_receiver`; generated fixture paths are stable across reruns.

The [batch evidence](qa/finder-source-transfer-2026-10-18.json) records the compile
name-collision repair, 35 passing Core cases and ten passing native case/engine
combinations. All ten receivers were reaped and independently absent. These
automated object/menu checks do not certify physical installed Finder delivery
or signed deployment.
