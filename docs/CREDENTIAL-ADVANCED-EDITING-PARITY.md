# Credential advanced editing — October 18, 2026

Source: `SettingGitCredential.cpp` at pinned commit
`7338078f8ddd924b8cddee35f512f2286072136d`, principally
`OnBnClickedButtonAdd` (171), `OnLbnSelchangeListUrl` (228), `Save` (523)
and `SaveSettings` (approximately 750–800), plus `IDD_SETTINGSCREDENTIAL`.

## Implemented family

The native Credential page keeps the source list beside Config type, URL,
editable Helper, Username and Use HTTP path component. Add New/Save and Remove
remain immediate actions. The property-sheet and standalone Apply buttons now
use partial Apply rather than invoking the explicit Add New/Save action.
Existing source icons and editable helper completion remain in use.

For a selected URL in its accepted file/scope, Apply writes only edited known
fields. A Core `GitCredentialFields` mask controls the actual Git writes. An
unrelated username change retains the complete ordered helper/reset chain,
unknown fields, and raw/repeated/implicit boolean values. Helper changes retain
repeated usernames and HTTP-path entries. Changing an optional field to empty
unsets its keys; an edited unchecked HTTP-path checkbox unsets that origin's
key, matching `SaveSettings`/`Save`. A higher-priority inherited true value can
therefore become effective again. Merely displaying an unchecked box never
materializes a false override. Native edits retain a touched-field mask even if
the user changes the checkbox and then returns to its original value.

An existing username-only/HTTP-path-only group accepts Apply without requiring
a helper. Explicit Add New/Save, a new URL, or a different destination requires
at least one nonblank helper. Explicit Save confirms an existing destination
and writes all three known fields even if the draft otherwise looks unchanged.
For a new destination, blank Username and unchecked HTTP-path fields are
omitted as in `OnBnClickedButtonAdd`. Apply to a changed destination/URL writes
the helper plus only edited optional fields, matching `SaveSettings`' URL bit;
it neither asks the explicit Add overwrite question nor overwrites untouched
optional entries already at that destination. A destination/URL copy leaves the
source origin intact. The accepted included/XDG origin remains the target for edits
in place. Git locks and snapshot comparisons remain in effect; multi-key writes
are source-ordered and are not atomic, and an external edit during a write is
not covered by the initial snapshot check.

Selecting another group or New helper with pending edits now offers Save and
Discard, plus a native Cancel action. Save persists the old captured draft
before loading the captured target. Failure retains the old draft/selection.
Discard changes no configuration; Cancel keeps editing the old group. A single
selection operation blocks duplicate questions and retains existing Settings/
Quit ownership. The old binary confirmation seam remains only for older test
consumers; production uses the three-choice native sheet.

URL, Helper, Username, HTTP-path, Config type, simple-mode and list callbacks
all carry the accepted editor identity. Selection, Cancel, scope/mode changes
and retirement invalidate prior controls. Suspended permission/confirmation
operations capture the exact draft, target, field mask and snapshot. Retirement
prevents late permission acceptance from starting writes; already authorized
writes may finish but cannot replace a retired/reactivated page. Hidden owners
pass alpha and appearance to permission, replacement and selection sheets before
presentation. Existing helper passwords and Keychain remain outside these writes.

## Intentional macOS adaptations

The native selection question adds Cancel to upstream Save/Discard, and a failed
Save retains the current edited group rather than proceeding after a failed
source `SaveSettings` call. Ordered multi-helper/reset chains, included/XDG
origins and helperless groups are retained even though upstream's single helper
editor cannot show all those values together. An explicit helper edit replaces
the chain; clearing that field unsets it. Explicit full Save requires a nonblank
helper somewhere in the retained chain, allowing an inherited reset followed by
an actual helper. Shell-helper backslashes are retained; the Windows slash
normalization would alter valid macOS commands. Config scope copying preserves
the original origin. System writes use existing folder authorization rather
than an elevated Windows process. These adaptations do not establish signed
sandbox or privileged-write equivalence.

## Grouped verification prepared

Parent's initial grouped checkpoint passed the focused Core and six Credential
native case/engine combinations. Review then found that URL/destination Apply
used explicit Save's full field mask; the focused native correction above and
its new existing-destination assertion have not yet been rechecked. Parent owns
the affected native recheck; Core APIs/logic are unchanged by that correction.

- New Core `CredentialAdvancedEditingTests`: four real Git cases cover masked
  username/helper edits, untouched raw/repeated values and included origins,
  helperless edits, edited empty/unset fields and restored inheritance, stale
  snapshot and invalid-mask refusal.
- Existing `AuthenticationSettingsBatchTests` has its false-key assertion updated
  to source unset semantics; the remaining assertions are retained.
- New hidden `CredentialAdvancedEditingVerification.verify()` in
  `qa/credential-advanced-editing-native-2026-10-18.swift` uses a private repo,
  preference suite, real native page/helper editor and real Save/Discard/Cancel
  sheet. It covers actual masked writes, explicit Save/new-entry rules,
  helperless eligibility, included origin, existing-destination URL Apply with
  untouched repeated/raw optional fields and preserved source, callback retirement, failed selection
  Save, held permission/selection retirement and operation drain. It does not
  open a credential helper, Keychain, network or user pasteboard.
- Retained `CredentialSettingsVerification.verify()` now invokes explicit Save
  when checking replacement confirmation/Add, and tests malformed-helper
  validation instead of treating a valid helper removal as invalid.
  `CredentialSourceFamilyVerification.verify()` assertions remain applicable to
  helper/list refresh and selection lifetime. These two receivers should be
  included in the same cached grouped checkpoint rather than separate builds.

Every owned native window/sheet is hidden. Held continuations are resumed and
owned operations drained on success/failure. No full suite, hosted CI or physical
acceptance is claimed by the prepared cases.

## Remaining behavior and acceptance

Physical keyboard/accessibility focus of all source controls, exact light/dark
layout comparison, real system-folder authorization/elevation, installed helper
availability, Keychain handoff and signed/App Store acceptance remain open.
Native new-entry/include cases do not establish every XDG/worktree/no-repository
combination or multi-file partial-failure recovery. Git writes remain non-atomic;
there is no rollback promise. This family is a partial native replacement and
does not certify the whole Credential dialog, all Settings pages or the port.


The [grouped checkpoint](qa/credential-merge-workflows-2026-10-18.json) records
24 passing selected Core cases and 14 distinct passing native case/engine
combinations, including focused repairs and retained unaffected results. This
scoped pass does not remove the remaining acceptance limits above.


## Exact credential URL and field spelling — October 19, 2026

The [connected exact-text settings family](SETTINGS-EXACT-TEXT-PARITY.md)
addresses canonical-Unicode aliases in edited values, captured save guards and
Git config arguments. Its dated record separates grouped checks from remaining
physical, signed and full-source acceptance. Existing source write order,
permissions and partial-failure behavior remain in effect.
