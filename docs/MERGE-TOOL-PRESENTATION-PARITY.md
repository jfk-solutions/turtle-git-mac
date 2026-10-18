# Standalone Merge application presentation

This connected native adaptation follows pinned
`src/TortoiseMerge/TortoiseMerge.cpp::InitInstance`, its main-frame lifetime and
`src/Resources/TortoiseMergeENG.rc` File/Edit/View/Navigate/Help commands. It uses
the same `IDD_OPENDLG` Open/replacement workflow as the existing editor family.
It does not certify that all upstream main-frame commands or dialog layouts are
complete.

`TurtleGitLaunchMode.resolve` uses the actual Merge command parser before choosing
one of two concrete SwiftUI applications. `TurtleGitApplication.main` performs
shared rebase-editor and runtime initialization once, then calls either
`TurtleGitMacApp.main()` or `TurtleGitMergeToolApp.main()`. Each App declares a
static scene set; there is no unsupported conditional `SceneBuilder` content. Ordinary document requests and repository `/command`
requests retain the repository `WindowGroup`. Recognized tool arguments select a
Settings-only scene, including malformed requests that must report a tool error.
There is no repository window in this scene to create, hide, or flash on screen.
`WorkspaceSceneOwner` delays the production repository model until the repository
scene actually reads it, avoiding Finder-watch restoration simply from installing
App state objects.

The standalone scene has no `RepositoryWindow.onAppear`. The application delegate
therefore retains a minimal `RepositoryModel(startMonitoring: false,
initializePreferences: false)` and appearance owner, installs the native settings
service and delivers startup once. It does not install the automatic First Start
Wizard or release-update startup service. Previous-crash prompting is reserved
for ordinary workspace startup. Context Help remains installed for both modes.
The tool refuses automatic untitled-file and Dock-reopen workspace creation;
ordinary workspace behavior remains available. After launch finishes, the
standalone owner requests regular application activation once before its
asynchronous editor presentation. Direct Git execution does not otherwise create
a SwiftUI document window to activate the process. The subsequent native editor
can therefore become the actual key window and acquire its existing guarded menu
contributions; this does not relax commands to use an inactive/background owner.

The existing focused `MergeEditorCommandMenu` owns Open, Save, Save As and patch
creation, editing, navigation, view options and help. Standard menu roots are
resolved by AppKit Window/Help identities, responder actions, application-owned
keyboard bindings and the known standard App/File/Edit/View scaffold. Native
contributions therefore reuse the macOS-localized roots instead of creating
parallel English File/Edit/View/Help menus. Existing framework identifiers and
captions remain intact; optional TurtleGit identifiers belong to TurtleGit,
without assuming private SwiftUI identifier strings. New Navigate insertion uses
semantic role order. Retirement removes only the contributed commands and
empty roots created by that owner. Its actual model guards,
menu epochs, retired-owner refusal, permission choices and replacement workflow
remain in use. The standalone command provider omits repository New/Open Recent,
Clone/Create/Close Repository, repository actions and unrelated startup commands.
Standard macOS clipboard, Undo/Redo, Window and Quit are retained. A dedicated
Close command (Command-W) supplies the document action missing from a Settings-only
scene. It re-resolves the visible key tool/Open/patch/settings owner, rejects
foreign/closed/retired/sheet/Quit-confirmation owners, and calls `performClose`.
Existing controller save prompts and load cancellation remain authoritative;
it never force-closes a busy or dirty editor. The
application About entry identifies TurtleGitMerge. Merge Editor Settings continues
to open the shared native settings owner at the Merge page; Appearance remains
available in the global settings navigation, including Light/Dark/System choice.

Save All supplements the focused source menus, using Command-Option-S to avoid
the existing native Command-Shift-S Save As binding. The context observes the
current model, re-resolves the actual key window on invocation, rejects sheets,
field editors, readonly/retired models, pending operations and Quit confirmation,
and saves every dirty comparison pane rather than only the active pane. A clean
required merged result also participates. Three-file results use the existing
owned save flow without marking a repository conflict resolved. Background or
closed editors cannot receive a stale Save All invocation.

Tool termination continues to use the existing launch session: approved Quit
closes its owned editors, waits for active work and returns the actual saved or
discarded result status to the waiting Git process. Selecting a dedicated scene
does not replace this protocol with an independent termination path.

## Verification scope and remaining acceptance

`qa/merge-tool-scene-native-2026-10-18.swift` supplies
`MergeToolSceneVerification.verify()` for the grouped native runner. It checks
ordinary/tool/malformed classification, lazy workspace creation, retained
standalone bootstrap, one-shot activation/delivery, normal startup deferral, suppression
of untitled/reopen workspace requests, independent mandatory-output Save All,
inactive-pane Save All, background/closed/Quit refusal, guarded Close of clean
comparison/Open windows, and actual focused native
menu contributions with retirement, including application-menu replacement after
the editor became key (without a second focus callback), localized root reuse,
role order and preservation of framework roots/anchors after retirement. It uses private preferences/files and owned
invisible windows. The parent batch records actual build/check outcomes after its
checkpoint; this document does not assert a pass before that checkpoint.

The helper fixture does not launch a second SwiftUI App lifecycle. A built-app
process/UI smoke is separately needed to demonstrate physical absence of an
automatic workspace and actual Settings-only scene menu integration on supported
SDK/OS combinations. Displayed light/dark layout, keyboard focus/VoiceOver,
minimum-OS/Intel, signed sandbox terminal grants and whole-app source parity
remain separate acceptance work. Repository and tool scenes currently share the
application bundle identity/name, as the waiting wrapper executes that bundle's
binary; no separate installed TurtleGitMerge app bundle is created by this batch.
