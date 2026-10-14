# Commit status-list workflow ownership

Baseline: pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`GitStatusListCtrl.cpp` menu/selection/marked-row gates, working-file restore
commands, and CommitDlg's staging/changelist paths. This extends the existing
Commit and Working Tree family audits; it does not certify complete dialog parity.

Commit file menus now capture displayed files, the focus mark and an owner
revision. Every action uses that capture, including Compare, Add, Revert,
restoration copies, LFS/flags, history/Blame, Rename, Ignore/Resolve, clipboard,
changelists and group checkbox actions. Selection, refresh, pane mode, grouping,
directory classification and order changes retire the menu. Restoring an earlier
selection does not revive it. Original command icons and source status gates
remain; missing tracked paths can retain history/Blame and reveal their existing
ancestor without enabling Open on missing content.

Open With, Export, deletion and explicit Restore use owned native sheets and
captured pending replies. Their file operation stays busy and guards Quit until
its response/read settles, even after forced source-window removal. Late replies
repeat the source revision and retirement checks before dispatch. Close ends the
owned sheet and cancels its operation. A retired external-launch error cannot
reopen or update the owner. The verification receiver injects receiving
applications, so real external application behavior remains separate acceptance.

Staging/unstaging, flags, Add, deletion, Export, restoration-copy reads/writes and
changelist metadata operations now carry cancellation through the relevant Git
reads. The Commit dialog displays the operation title and a Cancel operation
control. Any completed changes survive cancellation and failed mutations refresh
the table while retaining their diagnostic. The file-operation cleanup releases
its own busy state before starting a new refresh; it cannot clear that refresh's
busy state afterward. The same cleanup correction applies to Working Tree.

A pending new-changelist name keeps its captured menu and rejects an obsolete
reply. Commit's ignore-on-commit behavior still removes checks and unstages its
captured paths when staging support is enabled, while ordinary named lists only
change metadata. Saved copy capture checks cancellation before publishing the
owned temporary copy; restore checks again before atomic file replacement.
Unversioned-copy support and symlink/mode handling retain the existing Core rules.
Completed replacements are not rolled back by a later cancellation.

Revert remains delegated to the existing native Revert progress workflow. Its
menu/confirmation handoff and completion callback are fenced against retired
Commit owners. Other progress families retain their own accounting and dialogs.
This batch does not replace those existing workflows or certify every mutation's
physical interaction and recovery path.

The grouped receiver is `commit-file-workflows-native-2026-10-14.swift`, alongside
Commit Drop and the Working Tree lifecycle/menu regressions. It uses private
repositories/preferences and controlled pending replies, real Export/Restore/
Delete/changelist APIs and a Git child that actually starts before cancellation.
An injected held refresh checks that cleanup cannot prematurely clear busy.
Actual results, any repairs and the unsigned/signed limits are in the dated QA
record. Full physical menu/panel/keyboard, Trash/editor/Finder activation, signed
sandbox grants, minimum-OS execution and full application parity remain open.
