# Conflict editor command and shared routing

Reference: `Commands/ConflictEditorCommand.cpp`, `CAppUtils::ConflictEdit` and
operation-aware conflict titles at pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`.

The standalone `conflicteditor` command accepts one selected file or submodule
and optional `alternative`. Native command syntax retains literal names; an
authorized path file preserves that flag and validates cardinality before an
explicit list deletion. The CLI supplies an explicit normal/alternative choice,
independent of ambient Option/Shift state. Bare and repository-root-only selections
are refused. An initialized conflicted submodule is resolved to its superproject
by the shared selection resolver.

Preparation captures the receiving window and preference store. It authorizes
the containing working tree, reuses live/saved grants, and resolves linked Git
metadata before discovery. Cached grants are read without recording a new open.
The normal workspace adoption/rollback transaction receives the validated root;
its captured owner remains authoritative. The original selected item remains
separate and routes only after successful adoption. Additional granted folders
are retained and saved with an existing repository record after acceptance; an
inability to save that extra access is reported without discarding live grants.

Shared routing reads and revalidates the captured conflict stages, then opens
Delete/Modify, Submodule, Image or Text Merge. File conflicts first honor the
captured merge-tool choice. The default external launcher receives captured
identity options as well as the merge settings and owner. Image detection and
all specialized native windows use the original preference store. Existing
source stage/rebase identities, icons, resolution actions, progress and recovery
remain part of their respective workflows.

Preparation and all four editor maps use exact UTF-8 keys. Canonically equivalent
paths cannot coalesce reads, cancel a peer, share Delete/Submodule windows or
remove another controller through a close callback. A repeated native entry
reuses its controller and retains an edited text result; it does not replace the
draft with newly read bytes. Backend mutation still uses the existing captured
stage validation, so a stale view cannot resolve a different conflict.

Pending command preparation and shared routing participate in workspace Quit
ownership before an asynchronous task starts, through real metadata/blob reads,
and until cancelled work returns. Owner closure and application retirement
cancel pending delivery; late results cannot open an editor or publish errors.
Native operation windows own their subsequent work. External tool input and
process lifetime remain governed by the existing merge-tool session.

[Batch evidence](qa/conflict-commands-2026-10-18.json) records actual Core/native
checks and repairs. Source Windows process exit codes, arbitrary invalid UTF-8
paths, concurrent external-tool configuration changes, all submodule child
Log/Reset metadata-grant cases, real authorization issuance/renewal, physical
input/VoiceOver/theme/pixel parity and current signed Finder/App Store acceptance
remain open. This family does not certify the entire port or every conflict dialog.

See [side identities](CONFLICT-IDENTITIES.md),
[exact conflict paths](CONFLICT-PATH-IDENTITY-PARITY.md),
[Delete/Modify](DELETE-CONFLICT-PARITY.md),
[Submodule conflicts](SUBMODULE-CONFLICT-PARITY.md) and
[Image conflicts](IMAGE-CONFLICT-PARITY.md).
