# Dialog coverage and remaining review

The pinned inventory contains **130 dialogs**: **114 have partial family audits**, **16 await a family review**, and **none are certified complete**.

There are 1659 inventoried static controls. 764 have recorded native mappings; 895 still have pending control reviews. Dynamic menus, runtime-created controls, full layout and signed acceptance require separate evidence. A partial family audit never clears its unmapped controls. Recorded control mappings also remain partial; they do not prove all associated behavior.

This generated table links explicit implementation/parity reviews and existing QA. Missing links indicate missing recorded evidence, rather than proof that a feature is absent. The full machine-readable ledger is [dialog coverage](dialog-coverage.json). Review decisions live in `dialog-coverage-reviews.json`; regeneration is pinned to the source commit.

| Source dialog | Family audit | Static control mappings | Recorded parity/evidence |
| --- | --- | --- | --- |
| `contrib/issue-tracker-plugins/ExampleAtlPlugin/ExampleAtlPlugin.rc` / `IDD_WAITDIALOG` | pending-review | 0/1 mapped; 1 pending | No recorded family document; 0 QA records |
| `ext/CrashServer/CrashHandler/SendRpt/SendRpt.rc` / `IDD_SENDREPORTDLG` | pending-review | 0/6 mapped; 6 pending | No recorded family document; 0 QA records |
| `ext/CrashServer/CrashHandler/SendRpt/SendRpt.rc` / `IDD_SENDFULLDUMPDLG` | pending-review | 0/6 mapped; 6 pending | No recorded family document; 0 QA records |
| `ext/CrashServer/CrashHandler/SendRpt/SendRpt.rc` / `IDD_ASKSENDFULLDUMPDLG` | pending-review | 0/7 mapped; 7 pending | No recorded family document; 0 QA records |
| `ext/CrashServer/CrashHandler/SendRpt/SendRpt.rc` / `IDD_SOLUTIONDLG` | pending-review | 0/7 mapped; 7 pending | No recorded family document; 0 QA records |
| `ext/CrashServer/CrashHandler/SendRpt/SendRpt.rc` / `IDD_SENDASSERTREPORTDLG` | pending-review | 0/6 mapped; 6 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseGitBlameENG.rc` / `IDD_ABOUTBOX` | partial-native-replacement | 0/6 mapped; 6 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseGitBlameENG.rc` / `IDD_GOTODLG` | partial | 4/4 mapped; 0 pending | [BLAME-PARITY](BLAME-PARITY.md); 3 QA records |
| `src/Resources/TortoiseLoglistCommon.rc2` / `IDD_FIND` | partial-native-replacement | 11/11 mapped; 0 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseMergeENG.rc` / `IDD_ABOUT` | partial-native-replacement | 0/7 mapped; 7 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseMergeENG.rc` / `IDD_DIFFLOCATOR` | partial-native-replacement | 0/0 mapped; 0 pending | [MERGE-LOCATOR-PARITY](MERGE-LOCATOR-PARITY.md); 1 QA records |
| `src/Resources/TortoiseMergeENG.rc` / `IDD_LINEDIFF` | partial-native-replacement | 0/0 mapped; 0 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseMergeENG.rc` / `IDD_FILEPATCHES` | partial-native-replacement | 3/3 mapped; 0 pending | [IMPORT-PATCH-PARITY](IMPORT-PATCH-PARITY.md); 24 QA records |
| `src/Resources/TortoiseMergeENG.rc` / `IDD_OPENDLG` | partial-native-replacement | 0/24 mapped; 24 pending | [MERGE-OPEN-PARITY](MERGE-OPEN-PARITY.md); 2 QA records |
| `src/Resources/TortoiseMergeENG.rc` / `IDD_SETMAINPAGE` | partial | 5/24 mapped; 19 pending | [MERGE-DEFAULT-ENCODING-PARITY](MERGE-DEFAULT-ENCODING-PARITY.md), [MERGE-PATCH-PARITY](MERGE-PATCH-PARITY.md), [TEXT-MERGE-PARITY](TEXT-MERGE-PARITY.md), [UI-PARITY](UI-PARITY.md); 13 QA records |
| `src/Resources/TortoiseMergeENG.rc` / `IDD_SETCOLORPAGE` | partial | 0/35 mapped; 35 pending | [MERGE-COLORS-PARITY](MERGE-COLORS-PARITY.md); 2 QA records |
| `src/Resources/TortoiseMergeENG.rc` / `IDD_FIND` | partial-native-replacement | 0/14 mapped; 14 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseMergeENG.rc` / `IDD_ENCODING` | partial-native-replacement | 0/7 mapped; 7 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseMergeENG.rc` / `IDD_GOTO` | partial-native-replacement | 0/4 mapped; 4 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseMergeENG.rc` / `IDD_REGEXFILTERS` | partial-native-replacement | 0/6 mapped; 6 pending | [MERGE-REGEX-FILTERS-PARITY](MERGE-REGEX-FILTERS-PARITY.md); 1 QA records |
| `src/Resources/TortoiseMergeENG.rc` / `IDD_REGEXFILTER` | partial-native-replacement | 0/8 mapped; 8 pending | [MERGE-REGEX-FILTERS-PARITY](MERGE-REGEX-FILTERS-PARITY.md); 1 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_ABOUT` | partial-native-replacement | 0/9 mapped; 9 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_ADD` | native-partial | 6/6 mapped; 0 pending | [ADD-PARITY](ADD-PARITY.md); 15 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_CHANGEDFILES` | partial-native-replacement | 0/15 mapped; 15 pending | [PRIMARY-DIALOG-VISUAL-REVIEW](PRIMARY-DIALOG-VISUAL-REVIEW.md), [STATUS-PARITY](STATUS-PARITY.md), [UI-PARITY](UI-PARITY.md); 16 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_LOGMESSAGE` | partial-workflow-replacement | 2/27 mapped; 25 pending | [LOG-PARITY](LOG-PARITY.md); 62 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_COMMITDLG` | partial-workflow-replacement | 44/45 mapped; 1 pending | [COMMIT-PARITY](COMMIT-PARITY.md), [PRIMARY-DIALOG-VISUAL-REVIEW](PRIMARY-DIALOG-VISUAL-REVIEW.md), [UI-PARITY](UI-PARITY.md); 47 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_PROMPT` | pending-review | 0/5 mapped; 5 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_RENAME` | partial-native-replacement | 6/6 mapped; 0 pending | [RENAME-PARITY](RENAME-PARITY.md), [UI-PARITY](UI-PARITY.md); 6 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_REPOSITORY_BROWSER` | partial-native-replacement | 0/10 mapped; 10 pending | [REPOSITORY-BROWSER-PARITY](REPOSITORY-BROWSER-PARITY.md); 7 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSMAIN` | partial-native-replacement | 0/16 mapped; 16 pending | [GENERAL-SETTINGS-PARITY](GENERAL-SETTINGS-PARITY.md); 1 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSOVERLAY` | partial-native-replacement | 0/23 mapped; 23 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSOVERLAYHANDLERS` | partial-native-replacement | 0/11 mapped; 11 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSPROXY` | partial-native-replacement | 0/14 mapped; 14 pending | [NETWORK-SETTINGS-PARITY](NETWORK-SETTINGS-PARITY.md); 2 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSMTP` | partial-native-replacement | 0/16 mapped; 16 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SVNPROGRESS` | partial | 6/8 mapped; 2 pending | [REVERT-PARITY](REVERT-PARITY.md), [UI-PARITY](UI-PARITY.md); 6 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SIMPLEPROMPT` | pending-review | 0/9 mapped; 9 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_INPUTDLG` | partial-native-replacement | 5/5 mapped; 0 pending | [EDIT-NOTES-PARITY](EDIT-NOTES-PARITY.md), [INPUT-DIALOG-PARITY](INPUT-DIALOG-PARITY.md); 3 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSPROGSADV` | partial-native-replacement | 0/8 mapped; 8 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_URL` | pending-review | 0/4 mapped; 4 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_TOOLASSOC` | partial-native-replacement | 0/7 mapped; 7 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_CHECKFORUPDATES` | partial-native-replacement | 0/13 mapped; 13 pending | [RELEASE-UPDATES-PARITY](RELEASE-UPDATES-PARITY.md); 1 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_REVERT` | partial-native-replacement | 6/6 mapped; 0 pending | [REVERT-PARITY](REVERT-PARITY.md); 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_LFS_LOCKS` | partial-native-replacement | 0/6 mapped; 6 pending | [LFS-PARITY](LFS-PARITY.md); 15 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_STATGRAPH` | partial-native-replacement | 45/49 mapped; 4 pending | [LOG-STATISTICS-PARITY](LOG-STATISTICS-PARITY.md); 8 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETOVERLAYICONS` | partial-native-replacement | 0/5 mapped; 5 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSPROGSDIFF` | partial-native-replacement | 0/12 mapped; 12 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSPROGSMERGE` | partial-native-replacement | 0/9 mapped; 9 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSLOOKANDFEEL` | partial-native-replacement | 0/9 mapped; 9 pending | [CONTEXT-MENU-SETTINGS-PARITY](CONTEXT-MENU-SETTINGS-PARITY.md); 1 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSDIALOGS` | partial-native-replacement | 28/28 mapped; 0 pending | [SETTINGS-NAVIGATION-PARITY](SETTINGS-NAVIGATION-PARITY.md); 5 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSDIALOGS2` | partial-native-replacement | 22/22 mapped; 0 pending | [SETTINGS-NAVIGATION-PARITY](SETTINGS-NAVIGATION-PARITY.md); 5 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_RESOLVE` | partial | 6/6 mapped; 0 pending | [RESOLVE-PARITY](RESOLVE-PARITY.md), [UI-PARITY](UI-PARITY.md); 8 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_DIFFFILES` | partial-native-replacement | 15/15 mapped; 0 pending | [LOG-PARITY](LOG-PARITY.md), [SUBMODULE-DIFF-PARITY](SUBMODULE-DIFF-PARITY.md); 63 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSCOLORS_2` | partial-native-replacement | 12/12 mapped; 0 pending | [SETTINGS-NAVIGATION-PARITY](SETTINGS-NAVIGATION-PARITY.md); 5 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSSAVEDDATA` | partial-native-replacement | 19/19 mapped; 0 pending | [SAVED-DATA](SAVED-DATA.md); 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_HISTORYDLG` | partial-native-replacement | 3/3 mapped; 0 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSHOOKS` | partial | 5/5 mapped; 0 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSHOOKCONFIG` | partial | 15/15 mapped; 0 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_EXPORT` | partial | 18/18 mapped; 0 pending | [EXPORT-PARITY](EXPORT-PARITY.md), [REVISION-EXPORT](REVISION-EXPORT.md), [SYNCHRONIZATION-PARITY](SYNCHRONIZATION-PARITY.md), [UI-PARITY](UI-PARITY.md); 44 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSTBLAME` | partial-native-replacement | 13/25 mapped; 12 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_CREATECHANGELIST` | partial | 4/4 mapped; 0 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSBUGTRAQ` | pending-review | 0/5 mapped; 5 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSBUGTRAQ_CONFIG` | partial-native-replacement | 0/42 mapped; 42 pending | [ISSUE-TRACKER-PARITY](ISSUE-TRACKER-PARITY.md); 8 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSBUGTRAQADV` | pending-review | 0/12 mapped; 12 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_AUTOTEXTTESTDLG` | partial | 9/9 mapped; 0 pending | [AUTOTEXT-TESTER-PARITY](AUTOTEXT-TESTER-PARITY.md); 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGS_CONFIG` | partial | 2/2 mapped; 0 pending | [ADVANCED-SETTINGS-PARITY](ADVANCED-SETTINGS-PARITY.md); 5 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_CLONE` | partial-native-replacement | 34/34 mapped; 0 pending | [CLONE-PARITY](CLONE-PARITY.md), [UI-PARITY](UI-PARITY.md); 9 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_GITPROGRESS` | partial-native | 6/7 mapped; 1 pending | [MERGE-PARITY](MERGE-PARITY.md), [PROGRESS-PARITY](PROGRESS-PARITY.md); 26 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_PULLFETCH` | partial-native-replacement | 0/25 mapped; 25 pending | [FETCH-PARITY](FETCH-PARITY.md), [PULL-PARITY](PULL-PARITY.md), [UI-PARITY](UI-PARITY.md); 16 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_PUSH` | partial-native-replacement | 0/29 mapped; 29 pending | [PUSH-PARITY](PUSH-PARITY.md), [UI-PARITY](UI-PARITY.md); 15 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SVNDCOMMITTYPE` | partial-native-replacement | 0/7 mapped; 7 pending | [SVN-PARITY](SVN-PARITY.md); 3 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_REQUESTPULL` | partial-native-replacement | 0/11 mapped; 11 pending | [REQUEST-PULL-PARITY](REQUEST-PULL-PARITY.md); 2 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_GITSWITCH` | partial-native-replacement | 1/19 mapped; 18 pending | [SWITCH-PARITY](SWITCH-PARITY.md), [UI-PARITY](UI-PARITY.md); 10 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_NEW_BRANCH_TAG` | partial-native-replacement | 1/24 mapped; 23 pending | [BRANCH-TAG-PARITY](BRANCH-TAG-PARITY.md), [UI-PARITY](UI-PARITY.md); 8 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_APPLY_PATCH_LIST` | partial-native-replacement | 0/14 mapped; 14 pending | [IMPORT-PATCH-PARITY](IMPORT-PATCH-PARITY.md); 24 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_FORMAT_PATCH` | partial-native-replacement | 0/24 mapped; 24 pending | [FORMAT-PATCH-PARITY](FORMAT-PATCH-PARITY.md); 2 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_MERGE` | partial-workflow-replacement | 27/27 mapped; 0 pending | [MERGE-PARITY](MERGE-PARITY.md), [UI-PARITY](UI-PARITY.md); 19 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_FIRSTSTARTWIZARD_START` | partial-native-replacement | 0/1 mapped; 1 pending | [FIRST-START-WIZARD-PARITY](FIRST-START-WIZARD-PARITY.md); 2 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSCOLORS_1` | partial-native-replacement | 21/21 mapped; 0 pending | [SETTINGS-NAVIGATION-PARITY](SETTINGS-NAVIGATION-PARITY.md); 5 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSCOLORS_3` | partial-native-replacement | 22/22 mapped; 0 pending | [SETTINGS-NAVIGATION-PARITY](SETTINGS-NAVIGATION-PARITY.md); 5 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_RESET` | partial | 19/19 mapped; 0 pending | [RESET-PARITY](RESET-PARITY.md), [UI-PARITY](UI-PARITY.md); 10 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_REBASE` | partial-native | 0/24 mapped; 24 pending | [REBASE-PARITY](REBASE-PARITY.md), [REBASE-REFERENCE-PREPARATION-PARITY](REBASE-REFERENCE-PREPARATION-PARITY.md), [UI-PARITY](UI-PARITY.md); 18 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_RESOLVE_CONFLICT` | partial | 14/14 mapped; 0 pending | [DELETE-CONFLICT-PARITY](DELETE-CONFLICT-PARITY.md), [UI-PARITY](UI-PARITY.md); 6 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_REFLOG` | partial | 8/8 mapped; 0 pending | [REFLOG-PARITY](REFLOG-PARITY.md), [UI-PARITY](UI-PARITY.md); 18 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SUBMODULE_ADD` | partial | 0/16 mapped; 16 pending | [SUBMODULE-ADD-PARITY](SUBMODULE-ADD-PARITY.md); 3 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGIT_CONFIG` | partial-native-replacement | 0/34 mapped; 34 pending | [GIT-CONFIGURATION-PARITY](GIT-CONFIGURATION-PARITY.md); 1 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINREMOTE` | partial | 18/18 mapped; 0 pending | [REMOTE-SETTINGS-PARITY](REMOTE-SETTINGS-PARITY.md), [UI-PARITY](UI-PARITY.md); 6 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SENDMAIL` | partial-native-replacement | 0/14 mapped; 14 pending | [SEND-PATCH-PARITY](SEND-PATCH-PARITY.md); 1 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SYNC` | partial | 26/27 mapped; 1 pending | [UI-PARITY](UI-PARITY.md); 6 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_CLEAN` | partial-native-replacement | 13/13 mapped; 0 pending | [CLEAN-PARITY](CLEAN-PARITY.md); 6 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_PATCH_VIEW` | partial-native-replacement | 0/1 mapped; 1 pending | [COMMIT-PARITY](COMMIT-PARITY.md); 40 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SVNIGNORE` | partial-native-replacement | 0/5 mapped; 5 pending | [SVN-PARITY](SVN-PARITY.md); 3 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSEXTMENU` | partial-native-replacement | 0/5 mapped; 5 pending | [CONTEXT-MENU-SETTINGS-PARITY](CONTEXT-MENU-SETTINGS-PARITY.md); 1 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_CREATEREPO` | partial-native-replacement | 5/5 mapped; 0 pending | [INIT-PARITY](INIT-PARITY.md), [UI-PARITY](UI-PARITY.md); 6 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSPROGSALTERNATIVEEDITOR` | partial-native-replacement | 5/5 mapped; 0 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_BISECTSTART` | partial-native-replacement | 9/9 mapped; 0 pending | [BISECT-PARITY](BISECT-PARITY.md); 2 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_STASH` | partial | 8/8 mapped; 0 pending | [STASH-PARITY](STASH-PARITY.md), [UI-PARITY](UI-PARITY.md); 12 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_REVGRAPHFILTER` | partial | 12/12 mapped; 0 pending | [UI-PARITY](UI-PARITY.md); 6 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_DIFFSUBMODULE` | partial-native-replacement | 17/17 mapped; 0 pending | [SUBMODULE-DIFF-PARITY](SUBMODULE-DIFF-PARITY.md); 1 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_IGNORE` | partial-native-replacement | 10/10 mapped; 0 pending | [IGNORE-PARITY](IGNORE-PARITY.md), [UI-PARITY](UI-PARITY.md); 7 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SUBMODULE_UPDATE` | partial | 15/15 mapped; 0 pending | [SUBMODULE-UPDATE-PARITY](SUBMODULE-UPDATE-PARITY.md), [UI-PARITY](UI-PARITY.md); 10 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_BROWSE_REFS` | partial-native-replacement | 0/11 mapped; 11 pending | [REFERENCE-BROWSER-PARITY](REFERENCE-BROWSER-PARITY.md); 18 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_ADD_REMOTE` | partial-native-replacement | 7/7 mapped; 0 pending | [REMOTE-DIALOGS-PARITY](REMOTE-DIALOGS-PARITY.md); 1 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_DELETEREMOTETAG` | partial-native-replacement | 0/7 mapped; 7 pending | [REMOTE-TAGS-PARITY](REMOTE-TAGS-PARITY.md); 1 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_REVISIONGRAPH` | partial | 0/0 mapped; 0 pending | [UI-PARITY](UI-PARITY.md); 6 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_USER_PASSWD` | pending-review | 0/6 mapped; 6 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_LOGORDERING` | partial-native-replacement | 4/4 mapped; 0 pending | [LOG-ORDERING-PARITY](LOG-ORDERING-PARITY.md); 2 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSCREDENTIAL` | partial-native-replacement | 0/18 mapped; 18 pending | [CREDENTIAL-SETTINGS-PARITY](CREDENTIAL-SETTINGS-PARITY.md); 1 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_MERGEABORT` | partial-native-replacement | 9/9 mapped; 0 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSDIALOGS3` | partial-native-replacement | 0/33 mapped; 33 pending | [GIT-CONFIGURATION-PARITY](GIT-CONFIGURATION-PARITY.md); 1 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_BUGTRAQREGEXTESTER` | partial-native-replacement | 0/8 mapped; 8 pending | [ISSUE-TRACKER-PARITY](ISSUE-TRACKER-PARITY.md); 8 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_CERTCHECK` | pending-review | 0/16 mapped; 16 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSUDIFF` | partial-native | 29/29 mapped; 0 pending | [UNIFIED-DIFF-VIEWER-PARITY](UNIFIED-DIFF-VIEWER-PARITY.md); 6 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_RESOLVESUBMODULECONFLICT` | partial | 26/26 mapped; 0 pending | [SUBMODULE-CONFLICT-PARITY](SUBMODULE-CONFLICT-PARITY.md); 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_FINDBAR` | partial-native-replacement | 0/6 mapped; 6 pending | [COMMIT-PARITY](COMMIT-PARITY.md); 40 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_COMMITISONREFS` | partial | 7/7 mapped; 0 pending | [COMMIT-CONTAINING-REFS-PARITY](COMMIT-CONTAINING-REFS-PARITY.md); 4 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_FIRSTSTARTWIZARD_USER` | partial-native-replacement | 0/7 mapped; 7 pending | [FIRST-START-WIZARD-PARITY](FIRST-START-WIZARD-PARITY.md); 2 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_FIRSTSTARTWIZARD_GIT` | partial-native-replacement | 0/13 mapped; 13 pending | [FIRST-START-WIZARD-PARITY](FIRST-START-WIZARD-PARITY.md); 2 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_FIRSTSTARTWIZARD_AUTHENTICATION` | partial-native-replacement | 0/11 mapped; 11 pending | [FIRST-START-WIZARD-PARITY](FIRST-START-WIZARD-PARITY.md); 2 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_FIRSTSTARTWIZARD_LANGUAGE` | partial-native-replacement | 0/6 mapped; 6 pending | [FIRST-START-WIZARD-PARITY](FIRST-START-WIZARD-PARITY.md); 2 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SELECTREMOTEREF` | partial-native-replacement | 6/6 mapped; 0 pending | [REMOTE-DIALOGS-PARITY](REMOTE-DIALOGS-PARITY.md); 1 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_SETTINGSWIN11CONTEXTMENU` | pending-review | 0/6 mapped; 6 pending | No recorded family document; 0 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_WORKTREE_CREATE` | partial | 23/23 mapped; 0 pending | [WORKTREE-PARITY](WORKTREE-PARITY.md); 6 QA records |
| `src/Resources/TortoiseProcENG.rc` / `IDD_WORKTREE_LIST` | partial | 5/5 mapped; 0 pending | [WORKTREE-PARITY](WORKTREE-PARITY.md); 6 QA records |
| `src/SshAskPass/SshAskPass.rc` / `IDD_ASK_PASSWORD` | partial-native-replacement | 4/4 mapped; 0 pending | [GIT-AUTHENTICATION-PARITY](GIT-AUTHENTICATION-PARITY.md); 3 QA records |
| `src/TortoiseIDiff/TortoiseIDiff.rc` / `IDD_OPEN` | partial-native-replacement | 8/8 mapped; 0 pending | [IMAGE-OPEN-PARITY](IMAGE-OPEN-PARITY.md), [UI-PARITY](UI-PARITY.md); 8 QA records |
| `src/TortoiseIDiff/TortoiseIDiff.rc` / `IDD_ABOUT` | partial-native-replacement | 0/5 mapped; 5 pending | No recorded family document; 0 QA records |
| `src/TortoisePlink/Windows/TortoisePlink.rc` / `IDD_LOGIN` | pending-review | 0/4 mapped; 4 pending | No recorded family document; 0 QA records |
| `src/TortoiseShell/resourceshell.rc` / `IDD_PROPPAGE` | partial-native-replacement | 31/31 mapped; 0 pending | [GIT-PROPERTIES-PARITY](GIT-PROPERTIES-PARITY.md); 1 QA records |
| `src/TortoiseUDiff/TortoiseUDiff.rc` / `IDD_FINDBAR` | partial-native-replacement | 0/6 mapped; 6 pending | [UNIFIED-DIFF-VIEWER-PARITY](UNIFIED-DIFF-VIEWER-PARITY.md); 6 QA records |
| `test/Cache/Cache.rc` / `IDD_CACHE_DIALOG` | pending-review | 0/12 mapped; 12 pending | No recorded family document; 0 QA records |
