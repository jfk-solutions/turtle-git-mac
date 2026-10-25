# Standalone Compare/Merge authorization

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
`TortoiseMerge/OpenDlg.cpp` validates selected inputs; the macOS adaptation must
first acquire sandbox authority for typed or command-line paths. A path supplied
by a terminal, drop or text field is not itself a file permission.

## Connected behavior

The command-line launch session distinguishes normal chooser cancellation from
a wrong selection and a fresh scope-acquisition failure. Cancel finishes the
waiting command unsuccessfully without reporting a saved-bookmark renewal error.
The native authorization picker validates the requested file/folder before
acceptance, so a wrong choice can be corrected in the picker. Injected or late
responses still pass the request's validation and current-owner fences. A real
fresh-access failure identifies its requested target rather than calling it an
expired repository bookmark.

A completed or cancelled authorization panel remains owned until it is detached
and hidden. Continuations and command completion are one-shot. Retirement cannot
release grants or launch a late editor while real preparation, native panels or
child work remains. Existing missing/future CLI input rules still authorize the
parent directory; output parents, patch source/target and generated unified-diff
output retain their separate captured requirements.

Interactive Open parses active role fields lexically before asking for missing
grants. After those grants, it validates actual input existence and directory
versus file requirements. The existing `MergeOpenRequest.selection` API retains
its filesystem-validating contract for other callers; the lexical stage does not
certify that files exist or authorize reads. Explicit nonexistent Open inputs
remain errors. Disabled/inactive fields and clipboard patch source handling keep
their source-mode semantics. Wrong selections, cancelled choices and changed or
retired forms cannot publish a new selection or save the Open radio preference.

These changes do not turn on a repository workspace, expand stored repository
permissions or weaken the Finder publication namespace checks. The transient
input/output grants stay with the owning tool/editor workflow.

## Evidence and limits

The [authorization checkpoint](qa/merge-authorization-2026-10-25.json) records
actual focused Core and grouped native results, including failures and repairs.
The existing Open and standalone-entry fixtures cover their real model/window
paths with private files, injected native chooser responses and owned cleanup.
Such checks do not prove arbitrary external signed sandbox grants, physical
Finder behavior, every upstream dialog, minimum-macOS/Intel execution or App
Store distribution acceptance. Installed build 7 predates this source family.

The final local checkpoint passes 13 focused Core methods, the combined arm64
Debug build, all four existing Open scenarios and the standalone launch scenario
with both system and bundled Git. All six owned receivers are independently
absent. The fixture-only Swift compiler bridge failure and the intentional
grant-before-metadata oracle correction remain recorded; passing assertions were
not removed. No unaffected Core suite or native family was repeated after those
fixture repairs.
