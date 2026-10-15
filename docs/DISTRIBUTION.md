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
python3 scripts/build-issue-regex-runtime.py
python3 scripts/build-lexilla-runtime.py
python3 scripts/build-graph-layout-runtime.py
python3 scripts/build-openssh-runtime.py
python3 scripts/build-git-runtime.py
xcodebuild -project TurtleGitMac.xcodeproj -scheme TurtleGitAppStore \
  -configuration AppStore -destination 'generic/platform=macOS' \
  -derivedDataPath build-store CODE_SIGNING_ALLOWED=NO build
```

Release and AppStore explicitly set `ARCHS = arm64 x86_64` and
`ONLY_ACTIVE_ARCH = NO` for the app and its target dependencies. Debug keeps
Xcode's development architecture behavior. Build distribution products with the
generic macOS destination so the package does not depend on the build host's CPU.
After building, audit the package:

```sh
python3 scripts/validate-app-bundle.py \
  build-store/Build/Products/AppStore/TurtleGitMac.app --require-git --require-universal
```

For a single build-and-audit entry point after preparing the pinned runtimes:

```sh
python3 scripts/build-distribution.py --configuration AppStore --derived-data build-store
```

Use `--configuration Release` for a future direct-distribution candidate, or
`--audit-existing` to inspect an already built candidate without another build.
The command creates `distribution-audit.json` only after package and cache-service
audits succeed. The report includes code hashes and slices and explicitly leaves
signing, sandbox execution and App Store submission unverified. A failed run clears
its previous owned success report. It does not publish or register the service.

The universal audit requires both slices in the app, Finder extension, embedded
cache service, Core/SMTP frameworks, WCRev and both askpass helpers. Component
runtime audits separately check the bundled Git and native runtime payloads.
A thin development build cannot pass distribution acceptance merely because
its Git runtime is universal. Architecture checks inspect binaries without
launching the app or registering the Finder/cache service.

This verifies compilation and unsigned packaging only. An unsigned AppStore configuration does not prove
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

The bundled Git executables use `Configuration/GitHelper.entitlements`,
which contains sandbox and sandbox-inheritance keys. Parent file permissions must
be active when the helper starts. Any helper code, dependent library, credential
component and additional executable must be bundled and signed appropriately.
These decisions follow Apple's [sandbox entitlement guidance](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html).

A linked worktree can refer to a Git directory outside the selected folder.
Submodules, local clone sources and external object stores can also need additional
folder grants. Clone now requests separate destination/source/key grants, holds
their leases and remembers a read-only key bookmark in the app-private identity
store. Successful native clones save the key path on the remote; old per-clone
bookmarks remain legacy compatibility paths. Signed Clone
grant inheritance and key renewal remain unverified. Init retains its destination
lease; normal and bare repositories save the resolved root to recents. Bare opening
is verified in a development preview, but signed Init grants, adoption and recent
bookmark renewal remain unverified. Workspace opening now discovers external
worktree/submodule metadata and recursive object-store dependencies before Git
launch, obtains owned folder grants and retains them through the session and child
windows. Saved grants renew/reuse on reopening, with primary repository boundaries
kept separate. See [repository folder access](REPOSITORY-FOLDER-ACCESS.md).
Injected Core/native checks do not prove signed helper inheritance or the full
Finder-service authorization lifecycle; those remain distribution acceptance gates.

## Pinned Git runtime — distribution acceptance pending

The build script pins Git 2.55.0 from kernel.org, verifies its SHA-256 archive
checksum against the pinned [publisher checksum](https://www.kernel.org/pub/software/scm/git/sha256sums.asc)
and builds arm64 and x86_64 with the macOS SDK and minimum target 13.0.
It uses system libcurl, crypto and compression libraries, avoiding Homebrew,
MacPorts and Fink search paths. Git’s optional Rust implementation is disabled
using its documented C build option. It includes the HTTPS transport and macOS
Keychain credential helper. Git LFS 3.8.0 is bundled from checksum-pinned official
arm64 and x86_64 publisher binaries, combined with lipo. Its source archive,
MIT/copied-Go notices, Go notices and notices for all 28 external Go modules
are included. Perl/Python tools and git-gui/gitk remain port work. The layout is:

```text
TurtleGitMac.app/Contents/Helpers/Git/
  bin/git
  bin/git-lfs
  libexec/git-core/       # Git subcommands and transport helpers
  share/git-core/templates/
  share/licenses/git/    # pinned source archive, licenses and reconstruction scripts
  share/licenses/git-lfs/ # source, publisher archives, dependency notices and repackage kit
  runtime-manifest.json
  git-lfs-manifest.json
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

## SSH response helper preparation

The app embeds the original Swift `TurtleGitSSHAskpass` CLI, built as an Xcode
tool target, under `Contents/Helpers/SSHAskpass/`. The embedding script signs it
with the configured identity; AppStore uses inherited-sandbox helper entitlements.
Provenance retains shipping source and post-sign binary hashes. The unsigned
bundle audit exercises a private dummy response and replay refusal, and checks
macOS 13/system linkage and both AppStore architectures. This does not verify
signed inherited invocation. Native Fetch/Pull/Push/browse transport wiring now
exists, and OpenSSH helpers are now embedded; real authentication and signed access
are still required before this enables App Store SSH authentication.

Native SSH identity bookmarks are created with read-only security scope and kept
in app-private storage. Git config receives only the native key path, never the
bookmark. Mock-provider tests are not evidence of real signed grants; signed
selection, stale renewal and loading from the sandbox remain acceptance gates.
See [identity selection](SSH-IDENTITY-PARITY.md).

## OpenSSH runtime foundation

A standalone pinned universal OpenSSH/static OpenSSL build retains source
archives, original licenses, reconstruction tools and file hashes. See
[OpenSSH runtime preparation](OPENSSH-RUNTIME.md) for build/audit commands and
explicit feature gaps. All Xcode configurations embed it under
Contents/Helpers/OpenSSH. Each helper is signed before the containing app;
AppStore signing uses inherited sandbox entitlements. Provenance preserves
unsigned binary hashes and records post-sign binary/file hashes. Unsigned builds
exercise fixture keys; inherited signed copies receive static signature and
entitlement checks, not execution from an unsandboxed Python parent.

Packaged Git now prefers bundled OpenSSH for ordinary SSH lookup; explicit
SSH commands retain precedence. AppStore runtime resolution requires the
executable client. Signed parent invocation, real authentication and complete
SSH behavior remain release gates.

The direct-mail MX dependency uses macOS DNS-SD through SDK libSystem, with no
bundled resolver or external process. Local read-only query/cancellation checks
and unsigned builds do not prove signed sandbox permission behavior. Direct-mail
submission/routing remains incomplete; see [Send Patch parity](SEND-PATCH-PARITY.md).

## Apple Mail draft permission

Mail-client delivery now has a compose-only Apple Mail adapter. AppStore.entitlements
requests `com.apple.mail.compose` through scripting-targets, plus the automation
permission; App-Info.plist explains that TurtleGit prepares drafts for review.
There is no temporary Apple Events exception or inbox access group. Signed TCC
permission, attachment access/import, account selection and Mac App Store review
remain required acceptance work. Unsigned packaging/audit results prove only the
configured metadata, not these runtime or distribution requirements. See
[SEND-PATCH-PARITY.md](SEND-PATCH-PARITY.md).


The 2026-10-12 [Git SVN component](GIT-SVN-RUNTIME.md) adds bundled Perl,
Subversion bindings and Serf transport to the pinned Git package. Executable
helpers receive inherited-sandbox signing; dylibs/XS bundles receive library
signatures without executable entitlements. Local ad-hoc execution and contained
loader paths are development evidence only; authenticated transport, minimum-
OS runtime, signed bookmarks/Keychain/trust and security/license acceptance remain
release gates.

The merge adapter shares those same private Subversion/APR libraries. Build it
after the pinned Git runtime with `scripts/build-merge-diff-runtime.py`; Xcode
embeds its universal executable, source/license reconstruction and provenance,
and configures inherited sandbox signing for App Store builds. A distribution
bundle audit now requires both SVN and the adapter. Actual unsigned loading
from the app bundle has been exercised on arm64 and x86_64; signed dynamic-library
validation, sandbox execution and minimum-OS acceptance remain open. The adapter
is a backend foundation and has not yet replaced the editor's current engine.

Lexilla preparation uses `scripts/build-lexilla-runtime.py`. Its universal
static helper contains the four engines used by pinned Blame, immutable source
keyword/style definitions, original Lexilla/Scintilla licenses and the pinned
source archive plus reconstruction scripts. Xcode embeds it in
Contents/Helpers/Lexilla and applies inherited helper sandbox signing for
AppStore. Bundle validation verifies hashes, source kit, architectures, minimum
OS and system-only dynamic linkage. Physical signed acceptance remains open.

## Embedded Finder cache agent

The service target is separately sandboxed and embedded under
`Contents/Library/LaunchServices`; its SMAppService plist is under
`Contents/Library/LaunchAgents`. Provision app, Finder extension and agent with
the same App Group, and sign all three with the same team. The helper loads the
containing app's frameworks/Git runtime. `scripts/audit-cache-service.py` checks
actual layout and unsigned fail-closed startup without registering a background
item. Both CI configurations invoke it. See
[deployment and remaining signed acceptance](FINDER-SERVICE-DEPLOYMENT.md).
Unsigned packaging passes cannot establish user-approved launch registration,
peer authentication enforcement or sandbox permission transfer.

## Production runtime code/data layout — 2026-10-13

The earlier ad-hoc signing failure was caused by mixed code/data trees under
`Contents/Helpers`: versioned Perl directories were interpreted as bundles,
and reconstruction headers were interpreted as unsigned code. Runtime packaging
now places native executables in `Contents/MacOS`, native libraries in
`Contents/Frameworks/TurtleGitRuntimeLibraries`, and other payloads in
`Contents/Resources/TurtleGitRuntimes`. Compatibility links preserve helper
lookup paths. Private native library references are rewritten before signing.

The full Debug app can now be sealed and verified with an ad-hoc identity using
its production layout. Documentation previews use that layout and preserve its
runtime signatures/provenance. The former preview-only relocation workaround
is no longer required for current builds. See [layout and validation](RUNTIME-LAYOUT.md).

This resolves the structural layout failure. It does not establish App Store
certificate/provisioning, actual inherited sandbox invocation, physical Finder
activation, user-approved cache-service registration, or licensing clearance.

## Debug preview auxiliary-code signing — 2026-10-13

Hosted run 38406476058 built and audited its Debug bundle, then failed to seal the
Finder extension because Xcode's `Contents/MacOS/__preview.dylib` was unsigned.
The preview signer now inventories each bundle's declared main executable, signs
other Mach-O payloads first (including auxiliary libraries in MacOS and versioned
frameworks), and seals containers from the inside out. Finalized runtime payloads
retain their provenance-bound signatures and hashes. No `--deep` signing is used.
Executable names and resolved main/metadata paths must remain inside the copied app.

Four inventory tests and a fresh actual signed Debug copy passed. Its 203-item
runtime layout, deep strict app seal, sealed-source tamper rejection, substituted/
undeclared-link rejection and repeat-finalization checks passed. This establishes
the ad-hoc development-preview seal on the current host, not Developer ID, App
Store signing, sandbox execution or distribution eligibility. No GUI was launched.

The current AppStore configuration also compiled universal x86_64/arm64 with
signing disabled. See the [scoped packaging evidence](qa/preview-signing-2026-10-13.json).
Unsigned preparation leaves inherited sandbox signing unverified.

Its unsigned AppStore bundle audit passed the 203 runtime code items, bundled
Git/Finder packaging, reconstruction/licenses and 296 upstream icons.

## Reviewable XCArchive and offline export

After the pinned runtimes are prepared, build a fresh universal archive:

```sh
python3 scripts/archive-distribution.py --configuration AppStore \
  --derived-data build-archive \
  --archive-path build/artifacts/TurtleGitMac-AppStore.xcarchive
```

The tool refuses to overwrite an existing archive. Use `--audit-existing` to
recheck it. The app is the only installed product; Finder and other dependencies
remain embedded. The audit verifies archive/application identity, both code
architectures, package/runtime/cache-service layout, a matching universal dSYM
for every app-owned executable/framework, and a file/hash/contained-alias inventory.
Its adjacent `.archive-audit.json` records the result. A failed run clears the
tool's previous success report, while preserving the archive for inspection.
The candidate is unsigned and does not prove sandbox or App Store acceptance.

Supplying the actual ten-character `--team-id` additionally prepares adjacent
`.ExportOptions.plist` settings. No example/placeholder team is generated, and
existing different settings are refused. The options use `app-store-connect`
for AppStore or `developer-id` for Release, with `destination=export`, version
management disabled and no symbol upload. These choices were checked against the
local Xcode command-line help; account/profile/certificate setup remains separate.

For a subsequently signed archive with its actual team/profile configuration:

```sh
python3 scripts/export-distribution.py \
  --archive-path /path/to/Signed-TurtleGitMac.xcarchive \
  --options /path/to/Signed-TurtleGitMac.ExportOptions.plist \
  --export-path /path/to/fresh-local-export
```

This entry rejects unsigned/ad-hoc archives, mismatched teams, upload/custom
settings and existing output directories before export. It does not request
provisioning updates. Xcode output stays in an owned staging directory until
signature, identity, universal package and cache-service audits pass. AppStore
packages are expanded for inspection, including their installer signature;
Release exports are inspected as applications. A failed package does not appear
at the requested successful output path. `export-audit.json` still marks signed
runtime/sandbox acceptance unverified. Nothing is uploaded, notarized or submitted.
A fully signed export is not claimed until tested with actual certificates and
profiles; licensing clearance, permissions, physical Finder integration and
App Review eligibility remain release gates.

The 14 October 2026 local candidate is
`build/artifacts/TurtleGitMac-AppStore-2026-10-14.xcarchive`, with its adjacent
archive audit report. All eight app-owned binaries and matching dSYMs contain
arm64 and x86_64, and 6129 archive members were inventoried. Universal package,
300-icon/runtime and embedded cache-service checks passed. The actual unsigned
archive was refused before export. The initial path-fixture and relocated-helper
symbol-name checks were corrected without rebuilding the archive; exact UUID
matching remains required. See [the scoped QA record](qa/distribution-archive-2026-10-14.json).
This is a local unsigned candidate, not an App Store submission-ready release.


## Local Release preview ZIP

`package-local-preview.py` consumes a successful Release distribution audit,
checks its code hashes and refuses inherited-sandbox payloads. It preserves the
source build, copies into a fresh staging directory, reuses the explicit signing
inventory while preserving finalized runtime bytes, then verifies the copied
app's ad-hoc seal, universal bundle and cache-service layout. The app/ZIP,
SHA256SUMS, LICENSE, NOTICE, installation notes and preview manifest are published
locally only after these checks. Existing output is never overwritten. The
script does not install, launch, register services, notarize, upload or submit.
This is a local preview path; signed runtime/Finder and App Store acceptance
remain governed by the [release blocker list](RELEASE-BLOCKERS.md).
