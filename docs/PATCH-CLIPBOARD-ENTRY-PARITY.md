# Clipboard patch entry through Finder and the native file chooser

Reference: `TortoiseShell/ContextMenu.cpp::ApplyPatch` and
`TortoiseMerge/OpenDlg.cpp` at
`7338078f8ddd924b8cddee35f512f2286072136d`.

## Finder

The existing Review/apply single patch command keeps its source menu clauses,
order, icon and Shift visibility. A selected `.patch`/`.diff` file wins. On another
eligible selected file, explicit invocation prefers the registered TurtleGit or
compatibility patch clipboard format. Menu construction does not read patch
contents, and ordinary copied prose/text does not alter Finder command routing.
The app's explicit Review Clipboard action and chooser can still accept plain
unified diff text as their documented macOS interoperability extension.

Finder captures the bytes before its asynchronous application handoff. The open
URL contains a random receipt, never the patch contents or an arbitrary temporary
path. A 0700 directory under the entitled App Group’s Library/Caches contains 0600 records. Atomic
publication and atomic claim preserve exact bytes and one-use delivery; symlinks,
FIFOs, malformed receipts and oversized/expired records are refused. The consumer
removes a claimed record on success or failure. Publication prunes only owned
record names, with a ten-minute age check and best-effort 32-record/256 MiB budget;
one snapshot is limited to 128 MiB. Expiry is checked on use/publication, not by a
background timer. Failed app launch discards the published receipt.

Missing shared-container permission produces an explicit app error directing the
user to Review Clipboard Patch. It does not fall back to an unprotected global
temporary source file. The receipt conveys no repository permission. The app
loads its captured bytes within the existing owned review preparation, obtains
real folder grants and retains target-matching confirmation. Repeated receipts
are ignored within the app's bounded recent-receipt list. Review does not adopt
the app's workspace or apply a patch without the existing explicit Apply action.

## Native patch file chooser

When Review asks for its source patch, **Use Clipboard Patch** is an AppKit
accessory button with the original patch icon. It reads the clipboard only when
pressed. Invalid clipboard text leaves the chooser open with an explanatory
message, allowing the user to copy a patch and try again. A valid snapshot retires
the file chooser before target selection, preserving bytes if the clipboard
changes later. No fabricated source-file permission or temporary source file is
needed for this choice.

Source and target panels now retain one-use response contexts. Native sheet
release precedes continuation, and Cancel/closed/old/duplicate button or panel
callbacks cannot replace a newer source or target. Existing caller chooser hooks,
strip/reverse controls, preview, target matching and explicit Apply remain.
The Merge Open dialog's existing From Clipboard checkbox remains another entry.

## Acceptance

The [grouped checkpoint](qa/clipboard-patch-entry-family-2026-10-17.json) passed
twenty focused Core cases and two native workflow/engine cases. The initial Debug
build found a catch-variable naming error in the new receiver; its repair passed.
The cache-location change did not change injected-root Core behavior, so those
passed checks were not repeated. Both receivers were reaped and independently
absent. Native checks dispatch the production accessory target/action and inject
panel responses; they do not establish physical sheet geometry.

Physical Finder dispatch,
clipboard privacy prompts, entitled cross-process App Group access, actual native
Open panel geometry/VoiceOver and broader patch format/size performance remain
separate acceptance work. An unsigned private-root fixture does not prove signed
Finder/App Store interoperability.
