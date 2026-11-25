# Remaining dialog resources and macOS adaptations

Reviewed against pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`
on 25 November 2026. This explains the source inventory; it does not certify
complete behavior, layout, physical input or signed acceptance.

A pending resource/control entry is a review item, not automatically a missing
Mac window. The [coverage ledger](DIALOG-COVERAGE.md) keeps those distinctions
and retains partial mappings rather than a feature-completion percentage.

## Existing native replacements

| Pinned resource or control family | Source behavior and native treatment |
| --- | --- |
| `IDD_LOGIN` | The TortoisePlink secure reply dialog maps to the existing native Git/OpenSSH askpass prompt, with runtime caption, secure response, OK/Cancel and one-shot retirement. See [the login review](SSH-PASSPHRASE-PARITY.md#login-resource-review--november-25-2026). |
| `IDD_SIMPLEPROMPT` | The remaining static text describes a username/password request. Native SVN prompts already provide realm, username, secure password, save policy and acceptance/cancellation. See [SVN authentication](SVN-AUTHENTICATION-PARITY.md). |
| `IDD_SVNPROGRESS`, `IDD_GITPROGRESS`, `IDD_SYNC` | Native activity/percentage controls replace Windows animation controls. The SVN progress button dispatches the current post-operation action; its resource caption is not a universal Show Log requirement. Existing Commit/submodule/post-operation actions have their own owners. See [progress](PROGRESS-PARITY.md) and [synchronization](SYNCHRONIZATION-PARITY.md). |
| `IDD_PATCH_VIEW` | The existing native patch viewer provides syntax, Find, zoom, selected-line/hunk staging and parent preview handoffs. A remaining control review is not an absent patch editor. See [patch presentation](COMMIT-PARITY.md). |
| `IDD_FIRSTSTARTWIZARD_LANGUAGE` | Bundled macOS localization catalogs replace Windows language DLL discovery/download/Refresh. Language selection is saved immediately and Finder captions are published independently. The native wizard explicitly asks for a manual application restart; unlike Windows' separate utility process, it does not automatically terminate other repository/editor work in the shared Mac application. See [First Start](FIRST-START-WIZARD-PARITY.md) and [languages](LANGUAGES.md). |
| `IDD_SETTINGSWIN11CONTEXTMENU` | Windows package/registry registration and its second shell menu mask are platform-specific. Native primary-menu selection, Select All/defaults and Finder extension management already provide the portable actions. The pinned implementation is `SetLookAndFeelPage.cpp`, not a separate Git command family. See [context-menu settings](CONTEXT-MENU-SETTINGS-PARITY.md). |

## Windows-only infrastructure and dormant controls

| Source family | Scope |
| --- | --- |
| Settings Create Library | Creates a Windows `IShellLibrary` and assigns its icon. Finder repository/watch management is the native workflow; no Git repository mutation is missing. |
| Overlay Explorer/elevation/A:/B: options | Describe Windows Explorer, elevation/cache bypass and drive letters. Finder Sync uses scoped repository access and native volume policies. |
| Overlay handler slot/registry notices | Describe Windows shell overlay-slot allocation, other Tortoise clients and Registry Editor. They do not describe a Finder API. See [native overlay settings](FINDER-OVERLAY-SETTINGS-PARITY.md). |
| First Start Cygwin/Msys2 options | Windows path/process compatibility choices. The Mac app has native executable selection, Extra PATH, Browse and version checks; the sandboxed build uses its included tools. |
| `IDC_KEEPFILELISTSENGLISH` and its label | Hidden in the pinned Dialogs 3 resource and without a C++ consumer. Adding a new setting would not port active upstream behavior. |
| `IDD_URL` / `CURLDlg` | The pinned class has no live caller outside its declaration/implementation/project references. Current Clone/remote/URL entry workflows remain separately implemented. |
| `IDD_STATGRAPH` file-changes-per-interval placeholders | The source label display and average/minimum/maximum assignments are commented out. These are not active summary rows to add. Active Statistics line components, date preference consumption and author-cutoff/style behavior are addressed in [Statistics parity](LOG-STATISTICS-PARITY.md). |

## Auxiliary resources

The Windows COM example's `IDD_WAITDIALOG` is a sample plugin progress surface.
The native issue-provider bridge has its own process and credential workflow;
Windows COM binaries cannot be loaded as macOS plugins. See [issue providers](NATIVE-ISSUE-PROVIDER-PARITY.md).

The five `SendRpt.rc` resources belong to Windows minidump/assert collection,
DrDump submission and server-side solution lookup. The Mac app instead uses
Apple-generated crash reports, local discovery, consent/review, Copy/Save and a
separate issue-form action. Direct Windows DrDump submission/solution lookup is
not implemented or claimed. See [crash-reporting scope](CRASH-REPORTING-PARITY.md).

`test/Cache/Cache.rc` / `IDD_CACHE_DIALOG` is an upstream developer test program,
not a shipped Git workflow. Native cache/watch behavior has its own implementation
and regression checks; no equivalent developer test window is shipped.

These findings do not clear unexplained controls by inference. Source mappings,
remaining review decisions and physical/signed acceptance stay explicit in the
ledger and the individual workflow documents.
