# Literal tool configuration and association routing — October 24, 2026

This family follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`:

- `Settings/SetProgsAdvDlg.cpp:38–79,179–188,202–260` loads/saves literal
  association keys and adds, finds, edits and removes the selected entry.
- `AppUtils.cpp:431–439` chooses Diff by destination filename, base filename,
  then destination extension; `288–293` applies Merge's extension/exact-filename
  policy, including its dotted filename convention.
- `Settings/SettingsProgsAlternativeEditor.cpp:76–124` browses and saves the
  selected literal editor path. `AppUtils.cpp:676–695` uses the configured editor
  path plus the file argument; it is not an arbitrary editor argument template.

## Native identities and source policy

Diff/Merge association patterns retain their existing leading-asterisk removal,
edge-whitespace trimming and case normalization. Their normalized keys now have
UTF-8 byte identities. Canonically equivalent Unicode spellings remain distinct
rules and can choose different tools. Case-only duplicates remain invalid.
Candidate filenames are lowercased for matching but are not trimmed like entered
patterns. Diff keeps destination-name/base-name/extension precedence; Merge keeps
its dotted exact-name before extension precedence. Disabled association/Shift
inversion, image-before-default routing, built-in adapters and invalid enabled
program refusal remain unchanged.

Advanced Add/Edit validation, duplicate detection, native sorting ties, persistence
and Restore Defaults use the same key identity. Restore replaces only shipped
adapter keys and retains unrelated rules and their UUID row identities. Editing
or deleting one Unicode spelling cannot silently replace its sibling. Localized
sorting remains native; byte order provides a stable tie-break when collation
considers two labels equivalent.

Program executable paths and argument templates compare by UTF-8 bytes. The same
applies to association pattern drafts, Alternative Editor paths and the connected
Unified Diff viewer. Settings Apply therefore notices a byte-distinct change,
including a command argument containing decomposed text; Cancel retains the
accepted byte spelling. Existing JSON/default keys are unchanged and no migration
normalizes stored names. Application-bundle versus executable choices, bookmarks,
placeholder substitution and literal process argv retain their existing policies.
This does not change unrelated application strings or Git reference comparisons.

macOS uses its existing Unicode lowercasing adaptation; exhaustive equivalence to
every Windows locale-specific case mapping is not claimed. A normalizing filesystem
can constrain two physically distinct executable paths, independently of preserving
configuration text and historical Git filenames.

## Native child and chooser ownership

Diff/Merge Advanced sheets capture the parent page presentation and association
draft. Leaving/revisiting a cached page invalidates the earlier receipt; late child
results cannot replace a newer draft. Advanced editor callbacks become terminal
when their actual presentation disappears. Cached page Apply remains available
through the Settings transaction after ordinary navigation, as before.

The shared application chooser captures owner generation and current draft. A
closed, moved-away-and-back or replaced owner, changed draft, consumed reply or
modal dialog cannot adopt a retained response. Actual native sheet release keeps
its selecting state and global ownership until detachment. Already-detached mock
or native replies settle synchronously. Cancel rejects later replies; forced
closure drains the accepted presentation without publishing a bookmark or error
to another owner. Choosers inherit the parent's appearance and visibility.

Alternative Editor now uses an observable owned chooser, disables its form while
Browse owns it and captures the same exact draft/current-path policy as Diff,
Merge and Unified Diff. Selecting TextEdit preserves the saved custom path. App
and executable validation, scoped bookmarks and existing runtime grants are reused.

## Planned grouped checkpoint

`LiteralToolConfigurationTests` adds four private Core methods: exact persisted
program/editor/viewer text; filename and extension precedence/case duplicates;
Merge disabled/Shift/default behavior; and actual executable delivery of literal
argument bytes. No public repository, credential or user preference is used.

`qa/literal-tools-native-2026-10-24.swift` and cached
`scripts/test-literal-tools.py` provide three native cases:

- real Diff/Merge/Alternative/Unified settings fields and Settings transaction
  Apply/Cancel, including byte-distinct edits and bookmark invalidation;
- actual Advanced native table, selected row, editor lifecycle, Add/Edit/Remove,
  duplicate refusal, Restore Defaults and persistence;
- actual installed Browse controls, real owned sheet detachment, changed literal
  draft refusal, accepted grant, forced owner closure and late-response refusal.

These settings controls perform no Git operations, so the three cases are not
artificially repeated under different Git executables. Receivers prohibit
activation, use invisible windows/private preferences, close owned children and
retain cleanup assertions. The four focused Core methods passed in the parent
checkpoint. The affected Debug build and all three native cases now pass, with
the focused production and fixture repairs described below. Physical
input/VoiceOver, signed bookmark renewal, all external receiving applications and
full source layout remain separate acceptance scopes. This is not certification
of complete Settings or application parity.

### Native canonical-only edit repair

The first forms receiver failed before Apply. A focused diagnostic then acquired
its actual native field editor and inserted the decomposed argument spelling;
AppKit retained those bytes while SwiftUI's `PlatformTextFieldCoordinator` left
the original composed model value unchanged. This was a production input bridge
failure, independently of the initial fixture's synthetic delegate delivery.
Diff/Merge arguments, association keys, Alternative Editor paths and Unified Diff
arguments now use a native byte-exact binding. Existing path-completion fields
already publish their native editor text directly. The shared control retains
native field editing, Undo, disabled state and accessibility labels and refuses
publication from detached, closed, sheet-blocked or retired owners. The fixture
now uses actual native editor insertion without an intermediate ASCII edit.
The affected Debug app rebuilt successfully; the forms and associations cases
passed against it. No Core changes or Core rerun were needed for this repair.

### Chooser action projection and grouped completion

The original chooser case searched for an `NSButton`, but this SDK renders the
installed SwiftUI Browse control through its hosting view and key-view proxy.
The prohibited, invisible receiver also exposes no SwiftUI virtual accessibility
children; its default native tab chain skips the button. Diagnostic attempts
recorded those separate limitations rather than substituting a direct chooser
call or changing system keyboard-access preferences.

The final fixture waits for the actual program field's nonzero layout, finds the
adjacent Browse control bounds, verifies a live owned content hit-test target,
and sends local mouse-down/up events to that window. It neither moves the user
cursor nor injects global input. The real installed Diff and Alternative Editor
Browse actions then passed all original sheet, draft-change, grant-once,
closed-owner and late-reply assertions. This verifies the native action route,
not physical pointer or VoiceOver acceptance.

The passing chooser log is `build/qa/literal-tools-chooser-repair6-2026-10-24.log`
(receiver 93083 reaped). The five preceding focused chooser diagnostics remain
recorded as failures, with receivers 92508, 92639, 92792, 92887 and 92953 reaped;
they did not justify rebuilding the app or repeating the passing forms,
associations, Core, metadata or metafile checks. The separate canonical-edit
production diagnostic is `build/qa/literal-tools-native-repair1-2026-10-24.log`
(receiver 91298 reaped). The parent checkpoint retains the earlier grouped
failure/build records and independently verifies receiver absence.
