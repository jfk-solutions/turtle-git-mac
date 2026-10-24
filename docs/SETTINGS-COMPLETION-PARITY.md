# Settings completion and owned close

Source comparison uses pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`. This is a connected Settings
completion-family review, not certification of every Settings page or of the
whole application.

## Source behavior

`src/TortoiseProc/Settings/Settings.h:64` derives `CSettings` from
`CTreePropSheet`; `src/Utils/TreePropSheet/TreePropSheet.h:77` derives that class
from `CPropertySheet`. `Settings.cpp` supplies page construction, initial
selection, Help and restart handling. It does **not** define separate
`OnOK`, `OnCancel` or `OnApply` implementations. The ordinary property-sheet
completion contract is inherited: Apply saves modified pages without closing,
OK applies before closing, and Cancel discards unapplied edits. A page that
refuses Apply prevents successful completion. This is not a global rollback of
pages that already saved.

Concrete page evidence includes:

- `Settings/SetDialogs.cpp:291–329`: `OnApply` reads the controls, stores its
  settings, clears its modified flag and delegates to the base implementation.
- `Settings/SettingGitConfig.cpp:288–299`: `OnApply` returns false if `SafeData`
  fails; it clears the save-needed/modified flags only after successful saving.
- `Settings/Settings.cpp:100–143`: repository-dependent pages join the same
  property sheet as global pages; Remote belongs to the captured repository.
- `Settings/Settings.cpp:151–173`: restart/cache refresh is a separate consequence
  of saved settings, rather than evidence that all edits were accepted.

The Mac adaptation additionally owns asynchronous reads, writes, native sheets
and child-window retirement. A successful Settings close must wait for those
owned lifetimes rather than be lost because a page began retiring immediately
after Apply. Retirement must not save an unapplied draft.

## Connected implementation scope

The implementation covers `SettingsNavigationController` and the shared
`SettingsTransaction` completion path, retaining `SettingsSheetController`'s
existing owned sheet-release contract:

- Keep Apply, OK and Cancel enabled states consistent with the actual transaction,
  page operations and owned children. Apply saves without closing; successful OK
  retains its close request through asynchronous Remote retirement and completes
  once the owner is safe to release.
- Keep validation or save failures open on the relevant page, preserving editable
  drafts and already successful writes. Do not reinterpret a failed final page
  as a completed OK operation.
- Discard unapplied changes on Cancel or ordinary native close. Preserve changes
  already committed through Apply or an immediate page operation.
- Before successful Apply/OK completion, refuse stale replies after repository
  or participant replacement. A final awaited participant must still belong to
  the same registration when its reply returns. Retirement and owner closure
  also invalidate unfinished work.
- Retire only the children owned by this Settings instance, wait for actual sheet
  detachment, and deliver its completion callback once. After Cancel or successful
  OK accepts a terminal close intent, freeze the original Settings window and
  pages. A later change to the main workspace may finish closing that original
  captured window; it must not adopt a replacement page or close a new controller
  or window. The pending close cannot become a later Settings operation.

The sidebar, page contents, source icons, preference scope and existing per-page
Git actions stay in their existing families. This batch concerns their shared
completion and lifetime behavior.

## Meaning of the sheet callback

`SettingsSheetController.onClosed(Bool)` reports an ordinary, non-retired
Settings sheet release with its parent available. The Boolean is **not** an
“OK saved everything” receipt. Ordinary Cancel can return true: a caller may
need to reread settings that were applied earlier in the same visit.

Rebase, Stash and Merge identity callers use return from Settings to recheck
identity; Commit and the shared Notes identity session also perform their own
checks. Closing Settings never certifies that Git author/committer data is valid.
Parent retirement, cancellation and failed presentation must not resume work as
an ordinary accepted return.

## Validation status and remaining limits

Eight distinct native case/engine pairs pass cumulatively across the recorded
attempts: Close, Apply, Ownership and Layout with system and bundled Git.
Receiver: `docs/qa/settings-completion-native-2026-10-24.swift`;
runner: `scripts/test-settings-completion.py`. This is local native evidence,
not a complete hosted CI or signed acceptance result.

The initial final Layout receiver emitted an `Illegal NSTableView data source`
diagnostic after its PASS message. The repair detaches Remote's data source
before its delegate, then disables and clears the retired table's rows/actions.
The Close case now asserts that actual cached-table retirement. The affected
Debug build exited zero, and focused Close/Layout checks with both Git engines
passed four case/engine pairs without that diagnostic. Earlier passes are
retained; the full eight-pair group was not repeated after this focused repair.
The four captures show active UI and are unchanged by the retirement repair.

The receiver uses actual footer targets, Escape-button dispatch and native window
close paths. It covers cached Remote retirement, unapplied draft discard, a real
Remote URL Apply that stays open, validation/save failures followed by successful
OK, owned child sheets and held Git reads, retired and replacement owners,
original-delegate refusal, final participant replacement during awaited Apply,
and forced retirement during Apply. Private repositories, preference suites and
owned helper cleanup keep these checks isolated. These synthetic events do not
prove physical keyboard or accessibility acceptance.

The parent inspected four actual WindowServer captures: full Git and Remote
Settings windows in light and dark appearance, with legible complete footers and
a native two-row Remote list. These are [Git light](site/assets/settings-completion-git-light.png),
[Git dark](site/assets/settings-completion-git-dark.png),
[Remote light](site/assets/settings-completion-remote-light.png) and
[Remote dark](site/assets/settings-completion-remote-dark.png).

Optional `--captures DIR` records those windows during the first Git engine's
Layout case. Other receiver windows remain invisible or offscreen; the deliberate
capture window is restored immediately afterward. These images do not certify
all pages, display configurations or physical interactions.

Physical keyboard/VoiceOver behavior, every page's independent validation and
Git operation, public-window placement, signed distribution and all upstream
Settings layouts remain separate acceptance work. Partial page writes are
retained after later failure; neither source nor this native transaction promises
an atomic settings rollback.
