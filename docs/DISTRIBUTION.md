# Distributing TurtleGit for Mac

*A macOS fork of TortoiseGit*

The Mac App Store is a target distribution channel, not a verified release path.
The full port, signed runtime tests and licensing clearance remain incomplete.
The current development app uses the installed Git executable; the App Store
configuration deliberately refuses to fall back to that executable.

## Build channels

| Channel | Configuration / scheme | Repository access | Git engine |
| --- | --- | --- | --- |
| Development / future direct distribution | Debug or Release / TurtleGitMac | File picker, saved security-scoped bookmarks; app currently unsandboxed | Bundled engine if present, otherwise `/usr/bin/git` |
| App Store preparation | AppStore / TurtleGitAppStore | Sandbox, user-selected read/write folders, app-scoped bookmarks, network client | Requires `Contents/Helpers/Git/bin/git`; missing runtime is an error |

```sh
xcodebuild -project TurtleGitMac.xcodeproj -scheme TurtleGitAppStore \
  -configuration AppStore -destination 'platform=macOS' \
  -derivedDataPath build-store CODE_SIGNING_ALLOWED=NO build
```

This verifies compilation only. An unsigned AppStore configuration does not prove
sandbox permissions, inherited child-process access or App Review eligibility.
The engine has not been bundled yet, so this build cannot currently perform Git
operations. Debug retains installed-Git support for port development.

## Sandbox design

The app holds a security-scoped access lease for an open repository until that
session closes. Git operations complete before the scope is released. Repository
bookmarks persist in the app's private Application Support directory; a sandboxed
build uses its container's directory. They are not placed in the shared Finder
snapshot. Stale bookmarks are renewed while access is active. A failed renewal
requires selecting the folder again. A Finder URL is treated as a request: it
must match an existing permitted folder or be authorized through a file picker.

The Finder extension receives file paths and status badges, not repository access
bookmarks or credentials. Parent and extension share an App Group. That group
must be registered under the distributor's team and updated consistently in
both entitlements and `FinderIntegration.group`.

The AppStore configuration uses these capabilities:

- `com.apple.security.app-sandbox`
- `com.apple.security.files.user-selected.read-write`
- `com.apple.security.files.bookmarks.app-scope`
- `com.apple.security.network.client`
- The shared application group

The future bundled Git executables use `Configuration/GitHelper.entitlements`,
which contains sandbox and sandbox-inheritance keys. Parent file permissions must
be active when the helper starts. Any helper code, dependent library, credential
component and additional executable must be bundled and signed appropriately.
These decisions follow Apple's [sandbox entitlement guidance](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html).

A linked worktree can refer to a Git directory outside the selected folder.
Submodules, local clone sources and external object stores can also need additional
folder grants. Clone now requests separate destination/source/key grants, holds
their leases and persists a key bookmark for the cloned repository. Signed Clone
grant inheritance and key renewal remain unverified. Init retains its destination
lease; normal and bare repositories save the resolved root to recents. Bare opening
is verified in a development preview, but signed Init grants, adoption and recent
bookmark renewal remain unverified. General multiple-directory
workflows for worktrees, out-of-scope submodules and object stores are still pending;
basic bookmark tests do not prove those cases work inside the sandbox.

## Self-contained Git runtime — pending

Package a reproducible, pinned Git build (or a compatible in-process engine) rather
than requiring Command Line Tools, Homebrew or another installation. The CLI
runtime layout reserved by `GitRuntime` is:

```text
TurtleGitMac.app/Contents/Helpers/Git/
  bin/git
  libexec/git-core/       # Git subcommands and transport helpers
  share/git-core/templates/
  # all required non-system libraries and their notices
```

Audit every Mach-O dependency; avoid Homebrew paths and developer-machine RPATHs.
Provide the complete corresponding source and build instructions for bundled
GPL components. Test local and HTTPS operations, credential prompts, hooks,
filters, Git LFS and SSH independently. Existing external Git helpers and arbitrary
repository hooks do not automatically become usable in an App Store sandbox.
A bundled runtime must not execute external helpers to bypass restrictions.

`GitRuntime.environment` supplies the bundled exec path, template path and PATH.
This is only runtime selection infrastructure, not proof of a usable bundled Git.

## GPL and App Store terms — unresolved release gate

The project remains GPL v2, matching the upstream license in `LICENSE`. Rewriting
windows in Swift does not remove licensing obligations for a derived port.
No upstream licensing exception or permission has been obtained.

GPL v2 section 6 prohibits imposing additional restrictions on recipients. Apple's
[current standard application EULA](https://www.apple.com/legal/macapps/stdeula/)
contains usage and redistribution limitations and also recognizes separate EULAs
and open-source component terms. Whether a particular distribution arrangement
satisfies all relevant terms must be resolved before an App Store submission.
The FSF's [2010 App Store enforcement notice](https://www.fsf.org/news/2010-05-app-store-compliance/)
records a historical GPLv2 conflict; it is not a current legal clearance for this
project in either direction.

Do not change the license to work around this gate. Record the exact licenses of
retained upstream code, new code, assets and bundled dependencies, obtain any
necessary rightsholder permissions, and verify the proposed distribution terms.
Direct distribution remains an engineering path, subject to the same source and
license obligations. The App Store target is retained while this is investigated.

## Release evidence still required

- Full functional and UI parity audit; no unimplemented workflows presented as complete.
- A reproducible bundled engine and complete source/license distribution.
- Signed sandbox tests on clean Macs without developer tools or Homebrew.
- Signed Finder activation, badge updates and multi-selection menu tests.
- Additional folder permissions for worktrees, submodules and local remotes.
- Credential handling, cancellation, progress, conflict continuation and recovery.
- Universal or separately verified supported architectures and supported macOS versions.
- Distribution certificates, registered identifiers, provisioning and App Group access.
- App Store export/archive validation, privacy answers, metadata and screenshots.
- License/terms clearance, review notes and actual App Review acceptance.

Apple's [Mac App Store review requirements](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility)
require appropriate sandboxing and a self-contained Xcode-packaged app. Therefore
successful compilation and the presence of an AppStore scheme are insufficient
release evidence. Nothing has been submitted to Apple or uploaded as a release.
