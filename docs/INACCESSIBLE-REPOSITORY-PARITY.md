# Inaccessible repository diagnosis and explicit trust

Reference: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
The connected implementation below has passed its bounded grouped checkpoint.
This document does not certify the complete port.

## Source contract

`src/TortoiseShell/MenuInfo.cpp:29–30` defines **Inaccessible...** with
`IDI_CLEANUP`, mask `0x0010000000000000`, and an inaccessible-state condition
excluding ordinary versioned folders and bare repositories. The shell preserves
its ordinary-click visibility and forces top-level placement
(`ContextMenu.cpp:964,1006–1011,1300–1301`).
`SetLookAndFeelPage.cpp:44` excludes it from configurable menu rows. The existing
55-row Settings catalog therefore stays intact; the diagnostic is an additional
forced command, not another editable checkbox.

`src/Git/GitAdminDir.cpp:355–383` recognizes a bare-shaped folder using HEAD,
config, objects, refs and a refs/heads directory. A missing or non-directory
refs/heads in that shape reports invalid format. The shell treats that result,
or a failed working-tree root containing `.git`, as inaccessible
(`ContextMenu.cpp:423–424,496–497`).

`src/TortoiseProc/Commands/InaccessibleCommand.cpp:25–77` reports library-open
errors. Unsupported format, broken metadata and filesystem access failures are
not interchangeable with ownership denial. The source conditionally offers a
separate trust action for ownership denial or a non-directory `.git` marker,
except when the error identifies a non-repository. Only explicit acceptance
appends the root to protected global/XDG `safe.directory` configuration; earlier
values remain present. An existing global file takes priority; otherwise an
existing XDG file is used, with the global path the default when neither exists.

`src/TortoiseProc/Commands/Command.cpp:465–488` invokes the diagnosis when its
ordinary command preflight reaches a failed library repository open. It does not
retry the original Git operation automatically after adding trust.

## Finder and command entry

`FinderCache.swift`, Core `FinderContextMenuSettings.swift`,
`PrimaryCommandInvocation.swift` and `FinderSync.swift` expose the source command,
cleanup artwork, state exclusions and forced placement. The special Finder item
can appear without a cached repository root. A multiple-item popup captures only
its representative folder for diagnosis. Global path exclusions still apply.
The command is not hidden by the extended-only mask or moved into the submenu by
the configurable placement mask.

`/command:inaccessible` accepts one captured path, including the current directory
when no path is specified. Existing bounded path-file parsing and cancellation
apply; a rejected multiple-path file is not deleted. Literal path bytes survive
the command handoff. The native receiving boundary checks that the authorized
selection is a directory. Neither Finder URLs nor command arguments convey a
sandbox grant or consent to add trust.

Finder performs no Git operation to construct this item. Its filesystem/cache
classification is a native heuristic: an unwatched healthy root with `.git` may
offer diagnosis, and a stale known-root cache can suppress the entry after a
failure. A bare-shaped unsupported layout can offer diagnosis without `.git`.
A structurally recognized bare root remains excluded; Finder cannot establish
its ownership failure without opening it. The explicit command remains available
for a fresh diagnosis. The app must never convert a menu hint into trust consent.

## Fresh diagnosis and window ownership

`GitRepositoryDiagnosis.swift` and the dedicated helper operation inspect the
selected root without first adopting it into the workspace. Explicit diagnosis
uses the bundled libgit2 runtime independently of the ordinary master/mask
selection, following the source library diagnostic. The bounded response retains
an accessible/ownership-denied/not-repository/other-failure classification,
original library detail and captured engine configuration. Missing runtime,
malformed response and cancellation stay errors; they cannot grant trust.
Diagnosis does not write repository data or change ownership policy.

`RepositoryModel.swift` authorizes the requested folder before examining it and
retains its lease through the diagnostic. Both the manual entry and eligible
ordinary adoption failures can open the separate
`InaccessibleRepositoryWindow.swift` workflow. An unsuccessful adoption restores
the prior workspace rather than replacing its repository or drafts. Existing
folder permission is reused only when it covers the exact requested target.

The window provides original diagnostic text, Copy, Refresh, explicit trust,
Retry, Close and cancellation. Owned reads, questions and writes retain operation
accounting through actual settlement. Close during work requests cancellation
and waits for its drain; forced retirement fences late publication. Sheet
answers and cancellation await release of the exact owned sheet before another
sheet, final close or continuation. Quit includes diagnostic preparation,
operations and attached sheets rather than resetting counters on retirement.

Retry is an explicit native adaptation: it reopens the diagnosed root with its
retained permission, even when that grant covers a broader ancestor. It does not
repeat the failed Commit, Push or other original operation. A diagnosis of an
already accessible root is safe and offers no ownership-trust exception.

## Explicit trust and protected configuration

Git ownership trust and macOS folder permission are separate decisions. Trust
first computes global/XDG candidate paths lexically, without probing protected
files. The native workflow obtains the relevant directory permissions before
Core resolves existing files, canonical symlinks or the authoritative target.
This permits first-use sandbox authorization rather than failing before the
permission chooser. Git needs the containing directory for adjacent lock files;
a file-only grant is insufficient.

After authorization, Core captures the canonical repository, configuration
file and filesystem witnesses. The final trust question names that exact root
and destination. If the canonical destination needs a separate grant, it is
obtained before writing. Existing configuration permission helpers retain those
scopes. Canonical target changes or root/marker replacement require a new
inspection; the write cannot silently select a different global file after the
question. Literal Unicode spelling remains intact through the captured values.
Wildcard `*` and trailing `/*` broad-trust exceptions are not generated.

The native mutation uses captured Git in a neutral private directory and an
explicit `config --file <captured canonical file> --add safe.directory <root>`
operation, with invocation-only Unicode preservation. This is an explicit
implementation adaptation from the source's libgit2 config multivalue write.
It retains the source append behavior and global/XDG selection, without opening
the untrusted repository merely to change protected configuration. It does not
edit local configuration, rewrite unrelated values or change the stored Unicode
preference.

A write receipt records the actual destination and value. If an error or
cancellation follows possible publication, bounded readback compares the exact
safe-directory values: a confirmed append is retained, a known unchanged result
preserves the original failure, and an uncertain result is reported without an
automatic duplicate retry. Cancellation never claims rollback of a completed
write. A fresh diagnosis after publication may still report broken metadata;
adding trust is not presented as a repair for that failure.

## Checkpoint and remaining limits

Implementation/source review is recorded here; the dated evidence below records
the terminal Core, helper, app and native results. Automated fixtures used private
repositories, configuration files, preferences and owned responses. They did not
trust a user repository or launch the installed app for this family.

The additional active command is not one of the ten pending resource-dialog
families, so its implementation does not remove those ledger rows or certify
another dialog. The 55 configurable menu rows remain source-aligned. Resource
and control counts describe audit coverage, not feature completion.

Physical installed Finder gestures, first-use signed external configuration
permissions, real ownership denial under another user, VoiceOver, all filesystem
and concurrent-writer interleavings, and full hosted CI remain pending. Source
Windows process/elevation behavior has no claimed macOS equivalent. The Finder
heuristic and the explicit native Retry/config-write adaptations above remain
part of the documented scope; no complete source or distribution parity is
claimed.
## Grouped checkpoint, October 25, 2026

[The dated evidence](qa/inaccessible-repository-2026-10-25.json) records 83
selected Core methods passing cumulatively, eight distinct native case/engine
pairs, the actual Finder menu builder and the affected native Context Menu
Settings source case. The universal helper build reused both pinned static
library slices. Native receivers used private repositories/configuration and
invisible windows; every receiver was reaped.

The original failures remain recorded. They exposed a source menu-grouping
mistake, fixture assumptions about `/var` versus `/private/var`, an assertion
helper that incorrectly recorded intentional parser failures, and an incorrect
fixture expectation that a parent window could close through a modal sheet.
Repairs retain the source-order, literal-path, no-write, sheet-drain and
late-response assertions. The native ownership case also exercises the actual
alert Cancel button. Only affected checks were repeated.

The Debug app build returned exit zero with 35 contradictory compiler
exit-zero diagnostics recorded in its log. It preceded the final two-line
Finder grouping repair; the current Finder source was subsequently compiled
and exercised by the independent Finder receiver. This checkpoint therefore
does not claim a final rebuilt or installed distribution bundle. Hosted CI,
physical Finder activation, signed external grants, actual other-user ownership
denial, VoiceOver and complete visual/source coverage remain open.
