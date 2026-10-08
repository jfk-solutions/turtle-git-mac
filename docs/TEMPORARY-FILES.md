# Temporary files and Saved Data cleanup

Settings → Saved Data includes **Temp files (including Gravatar images) → Clear**.
It shows an Abort/Proceed question, with **Abort** as the default button. Before
proceeding, close other TurtleGit operations and external viewers using temporary
files. Clearing files while those operations use them can interrupt their work.

Proceed removes files and nested directories inside TurtleGit's dedicated temporary
folder. This includes cached Gravatar images and temporary preview copies. The
folder itself stays in place. The Clear button disables when nothing remains; if
items cannot be removed, it stays enabled and reports the remaining count. Abort
leaves files in place. Repeated clicks while the question is open are ignored.

TurtleGit's current temporary producers use `TurtleGitTemporaryFiles` beneath the
macOS user/application temporary directory. The folder has owner-only permissions.
This includes Git stdout/stderr captures, patch and checked-file lists, commit
message/index files, rebase editor data, notes, conflict-editor inputs, historical
and unified-diff previews, browser exports, local file-operation helpers, issue
parsers/project-properties helpers, Request Pull output and the Gravatar cache.
Existing per-operation cleanup and preview lifetimes still apply.

Cleanup targets only this folder. It preserves repository files, saved bookmarks,
histories and the persistent action log. Symbolic links inside the folder are
removed without deleting their outside targets. A substituted root symlink is
rejected. Temporary files created by older builds outside this folder are left
for their existing cleanup or macOS; the app does not scan arbitrary system temp
files. Documentation-preview bookmark storage is also excluded.

An author image already loaded into a Log window can remain visible. Images may
also remain in URLSession's system HTTP cache and be downloaded again. Clearing
this folder does not purge that cache or disable Gravatar. The warning adapts
TortoiseGit's corresponding Internet Explorer-cache notice to macOS.

## Source and verification

Adapted from pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`:
`Settings/SetSavedDataPage.cpp::OnBnClickedTempfileclear`,
`Git/Git.cpp::GetTortoiseGitTempPath`, and `Resources/TortoiseProcENG.rc`
(`IDS_PROC_WARNCLEARTEMP` and the Saved Data row). The native implementation
replaces Windows file attributes/directory deletion with recursive macOS removal
inside the private folder. It retries remaining items until their count stops
falling. It does not change Git repository files to achieve cleanup.

Core checks cover private preparation, an absent folder, read-only files, nested
Gravatar storage, symlink boundaries and exact-byte preview placement. Existing
Commit/patch/conflict/comparison/Rebase checks exercise the migrated temporary
producers. Native receivers use private fixture storage and injected decisions;
they do not clear the user's temporary folder or launch the main app. Run
`python3 scripts/test-temporary-files.py` after a Debug build.

Physical confirmation interaction, complete external-viewer coordination,
cross-process clearing during live operations, legacy temporary-file migration,
HTTP-cache purging and signed sandbox/App Store acceptance remain unverified.
The full Saved Data page and full application port remain incomplete.
