# Distributing TurtleGit for Mac

*A macOS fork of TortoiseGit*

The Mac App Store is a target distribution channel, not a verified release path.
The full port, signed runtime tests and licensing clearance remain incomplete.
Development builds can use the installed Git executable. The App Store
configuration requires a prepared pinned runtime and refuses external fallback.

## Build channels

| Channel | Configuration / scheme | Repository access | Git engine |
| --- | --- | --- | --- |
| Development / future direct distribution | Debug or Release / TurtleGitMac | File picker, saved security-scoped bookmarks; app currently unsandboxed | Bundled engine if present, otherwise `/usr/bin/git` |
| App Store preparation | AppStore / TurtleGitAppStore | Sandbox, user-selected read/write folders, app-scoped bookmarks, network client | Requires `Contents/Helpers/Git/bin/git`; missing runtime is an error |

```sh
python3 scripts/build-editorconfig-runtime.py
python3 scripts/build-git-runtime.py
xcodebuild -project TurtleGitMac.xcodeproj -scheme TurtleGitAppStore \
  -configuration AppStore -destination 'platform=macOS' \
  -derivedDataPath build-store CODE_SIGNING_ALLOWED=NO build
```

This verifies compilation only. An unsigned AppStore configuration does not prove
sandbox permissions, inherited child-process access or App Review eligibility.
The build phase embeds the prepared runtime into AppStore bundles and fails if
it is missing. Debug retains installed-Git support for port development.

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

## Pinned Git runtime — distribution acceptance pending

The build script pins Git 2.55.0 from kernel.org, verifies its SHA-256 archive
checksum against the pinned [publisher checksum](https://www.kernel.org/pub/software/scm/git/sha256sums.asc)
and builds arm64 and x86_64 with the macOS SDK and minimum target 13.0.
It uses system libcurl, crypto and compression libraries, avoiding Homebrew,
MacPorts and Fink search paths. Git’s optional Rust implementation is disabled
using its documented C build option. It includes the HTTPS transport and macOS
Keychain credential helper. Perl/Python tools, git-gui/gitk and Git LFS are not
bundled; those upstream workflows remain port work. The layout is:

```text
TurtleGitMac.app/Contents/Helpers/Git/
  bin/git
  libexec/git-core/       # Git subcommands and transport helpers
  share/git-core/templates/
  share/licenses/git/    # pinned source archive, licenses and reconstruction scripts
  runtime-manifest.json
```

The runtime validator checks every Mach-O file for both requested architectures
and Apple system-library dependencies, and rejects symlinks outside the runtime.
The package includes the unmodified source archive, COPYING, retained third-party
notices and reconstruction scripts. This supplies source/build material; complete
license and distribution-term clearance remains a release gate. Test local and HTTPS operations, credential prompts, hooks,
filters, Git LFS and SSH independently. Existing external Git helpers and arbitrary
repository hooks do not automatically become usable in an App Store sandbox.
A bundled runtime must not execute external helpers to bypass restrictions.

`GitRuntime.environment` supplies the bundled exec path, template path and PATH.
The Xcode AppStore post-build phase validates and copies the runtime before app
signing. When Xcode signing is enabled it signs each Mach-O helper with the
configured identity and `GitHelper.entitlements`. Unsigned compilation does not
verify inherited sandbox access or signed helper behavior.

```sh
python3 scripts/validate-app-bundle.py \
  build-store/Build/Products/AppStore/TurtleGitMac.app --require-git
```

The macOS CI workflow builds this pinned universal runtime and requires its
presence in the AppStore bundle. Build host tools are required to produce the
app; they are not an installation requirement for its packaged engine. Tests on
clean machines and supported OS/architecture combinations remain necessary.

## Runtime build evidence

On 2026-10-04 the pinned C-only Git 2.55.0 runtime built for arm64 and x86_64.
All 11 Mach-O files passed architecture, macOS minimum-target and system-library
dependency checks; runtime symlinks stayed inside the package. The assembled
runtime occupied about 60 MiB, including its source archive and reconstruction
material. Actual local init, commit, diff, stash push/pop, non-local-protocol
clone and log checks passed on the arm64 build host after relocation to the
runtime directory. Public HTTPS ls-remote against TortoiseGit passed with the
bundled HTTPS transport and user Git configuration disabled.

The unsigned Xcode AppStore build succeeded, its bundle contained the engine,
and `validate-app-bundle.py --require-git` passed for the app, Finder extension,
all 57 upstream artwork resources and bundled Git. Missing-runtime embedding was
rejected before changing a disposable app bundle. Nine repository-access tests
passed. The application repository constructors were audited: app opening,
Clone, Init and child repository handoffs select or carry the explicit engine.
No GUI test instances were launched for these command-line packaging checks.

These results prove unsigned packaging and arm64 local/HTTPS engine execution.
Intel runtime execution, macOS 13 runtime compatibility, signed helper inheritance,
Keychain prompts, credential/error paths, SSH, hooks, filters, LFS/SVN and clean-Mac
acceptance remain unverified. The optional Rust backend and excluded companion
tools do not establish full upstream Git/TortoiseGit workflow parity. No App Store
submission or licensing clearance has occurred.

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

## EditorConfig helper

All configurations embed the pinned universal EditorConfig C Core/PCRE2 parser
with source archives, reconstruction script and original licenses. Preparation
is mandatory before direct Xcode builds. AppStore signing adds the inherited
sandbox entitlements; other configurations sign the helper without inheritance.
The embedding audit verifies the prepared unsigned runtime before signing and
checks the signed binary hash, signature and exact sandbox entitlements after.
An inherited helper cannot execute from an unsandboxed Python build validator.
Signed app invocation, security scopes and ancestors outside a chosen repository
remain unverified; see [EditorConfig parity](EDITORCONFIG-PARITY.md).

## Issue-matching helper

All configurations also embed the universal C++ ECMAScript matcher, its complete
source, reconstruction/validation scripts and GPL license. Prepare it with
`python3 scripts/build-issue-regex-runtime.py`. The signing paths follow the
EditorConfig helper's sandbox inheritance rules. Both CPU slices and both
ad-hoc helper signing branches are checked; signed native App Store invocation,
actual Intel/macOS 13 execution and complete issue-control parity remain pending.
See [issue tracker parity](ISSUE-TRACKER-PARITY.md).
