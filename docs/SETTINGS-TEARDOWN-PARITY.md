# Settings graph teardown and owned continuations

This connected repair covers Git, Credential, Network, General, Context Menu,
Merge main/colors, Remote, Hook Scripts and Email Settings, together with the
shared Settings transaction. It addresses the hosted `replay/system` abort in
`hosted-ea108cf9-history-failure.log`: Git Settings closed after a held native
footer transaction, and `GitConfigurationSettingsModel.deactivate()` sent Combine
publication while SwiftUI/AttributeGraph held exclusive destruction access.
The backtrace identifies graph teardown rather than a Git command failure.

The source baseline is TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`. Relevant source families are
`Settings/SettingGitConfig.cpp`, `SettingGitCredential.cpp`, `SetProxyPage.cpp`,
`SetMainPage.cpp`, `SetLookAndFeelPage.cpp`, `SettingGitRemote.cpp`,
`SetHooks.cpp`/`SetHooksAdv.cpp`, `SettingSMTP.cpp`/`UserPassword.cpp`, and the
TortoiseMerge Settings pages. Their existing property-sheet Apply/Cancel,
source/destination choices, drafts and independent child-dialog actions remain
the behavioral reference. SwiftUI graph retirement and AppKit sheet detachment
have no Windows resource equivalent and require an explicit native lifetime.
This batch does not map additional source controls or certify these whole pages.

## Native behavior

Deactivation revokes command and editor authority immediately, rotates captured
receipts and cancels owned reads. It performs no synchronous `@Published` setter,
`objectWillChange.send`, native view refresh or terminal callback from a probe's
`dismantleNSView`, an `onDisappear`, or an owner-close notification. Observable
reset is queued after graph destruction and checked against the retiring
activation. Reopening a cached model before that reset preserves the new editor,
page, draft and attachment. Stable owner/probe receipts prevent an old view's
later teardown from retiring the replacement view.

Cancellation does not mean a worker has returned. Read/save/selection counters
remain owned through the actual asynchronous return; stale results cannot update
the replacement page. Credential selection questions retain their accepted task
until its reply returns. Git folder and Network SSH selectors retain ownership
until the captured AppKit panel actually detaches. General executable/version
and update-question callbacks follow the same captured owner and generation.
Cached hidden-page Apply remains available through the owning transaction;
retired editor controls cannot regain write authority through an old binding.

Merge Comment Profiles clears only the captured editor session and retains its
counter through the actual sheet release. Hook Scripts closes its captured
configuration editor and any picker before returning its one-shot completion.
Email credential replies retain their model and counter until the actual
credential window detaches; duplicate/retired answers cannot store a password.
Keychain access is unchanged by this lifecycle repair. Remote controls revoke
synchronously; their queued reset, captured modal release and settings reply
cannot revive a closed page. Shared Settings invalidation captures draft Cancel
callbacks and runs them outside graph destruction instead of reentering cached
page models from the destructor stack.

## Grouped verification

The new [native fixture](qa/settings-teardown-native-2026-10-18.swift) observes
`objectWillChange` on the same stack as retirement, checks immediate stale
binding/command refusal, late read cancellation and actual worker ownership,
reopening before deferred reset, and obsolete attachment safety. It destroys
actual production pages hosted by `NSHostingController`, including their native
window probes and Remote representable. It also checks captured Merge/Hook
sheets, SMTP reply ownership, and deferred shared-transaction draft cancellation.
All repositories, configuration, preferences and password stores are private;
password stores are injected and reject writes. Test windows and children stay
invisible. Owned continuations are resumed and windows/workers drained on failure.

`scripts/test-settings-teardown-family.py` builds one cached receiver with stable
source paths. The default group includes the new teardown case, the unchanged
failing Replay identity fixture, retained Git configuration/lifecycle,
Credential, Network, General, Context Menu, Merge and Remote consumers, Email
credential editing, and the Properties Settings held-footer transaction. Each
case/engine receives private global/XDG Git configuration. `--only replay`
reproduces the hosted failing workflow without the unrelated Log/Blame suites;
`--only teardown` isolates the new lifecycle contract. Existing behavioral
assertions now wait for actual sheet/reply completion where needed; they still
check the same state, mutation, one-shot, preference and Quit guarantees.

The [grouped checkpoint](qa/settings-teardown-2026-10-18.json) passed 24 distinct
case/engine pairs across system and bundled Git. It records two fixture setup
repairs and the retained consumer failure that required the accepted-save repair;
only affected paths were repeated. All 28 launched receivers, including failed
attempts, were reaped and independently absent afterward. The Debug build and
focused repair build passed; Core was not repeated for this native-only change.
A local checkpoint cannot prove hosted SDK/Intel execution, physical
mouse/keyboard or VoiceOver acceptance, signed Keychain/security-scope behavior,
Finder deployment, or complete Settings/window parity. The individual family
documents retain their source-specific missing controls and platform differences.
