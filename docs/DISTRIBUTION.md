# Distributing TurtleGit for Mac

*A macOS fork of TortoiseGit*

Local testing comes before publication. The installed candidate is signed build52;
the working source tree contains later changes and is a separate testing target.
There is no public App Store listing or submitted release. The App Store remains
a future distribution channel, with full-port acceptance, distribution signing
and the existing license/Store terms review still open.

## Installed signed local testing build52

The [signed build52 receipt](qa/signed-consolidation-build52-2026-11-03.json)
records the installed `0.1.0 (52)` candidate:

| Item | Recorded identity |
| --- | --- |
| Installed application | `/Applications/TurtleGit for Mac.app` |
| Exact clean source | `3702643e020511fc09687cda58f352ad5d12e459` |
| Build-input SHA-256 | `08cf03802df0e3677370e567728a9ecca0a4f7468e0c4d7b94327308d3cf7b8a` |
| Signing channel | Apple Development, sandboxed AppStore configuration for local testing |
| Local package | `TurtleGit-for-Mac-0.1.0-build52-signed.zip` |
| Package SHA-256 | `a36abefa6155fe5918c084a701d8608809eb573312fa76e73baa9404895675c0` |
| Matching source archive | `TurtleGit-for-Mac-source-3702643e020511fc09687cda58f352ad5d12e459.tar.gz` |
| Source archive SHA-256 | `b58fdfe1ddea098d7f2ed6a0821a9d23fc80662e66c64a30fbe68ed752da5376` |
| Preserved rollback | `build/local-testing/TurtleGit-build51-before52-2026-11-03.app` |

The source archive matches all 10,435 tracked files, blobs and modes of that
revision. Runtime source archives, reconstruction inputs and notices remain
separately included in the packaged runtime payloads. The ZIP contains
424,010,371 bytes; copied and extracted inventories and strict seals agree.
Installation preserved build51 and registered the new installed path without
restarting Finder/Dock or quitting unrelated apps.

The candidate passes its recorded universal-component, entitlement, strict-seal,
runtime-layout, Help and complete package/install inventory checks. A
candidate-specific signed parent also exercises public Core/Git local tools and
drains its owned processes. These checks do not establish a complete hosted pass,
physical Finder acceptance or Store approval.

Build52's installed workspace and Commit were exercised with a private
34,304-path repository and an existing 106.6 MB warm Finder cache. The workspace
was ready at the first 1.225-second post-open observation while optional Finder
publication continued; Commit showed the correct two rows at its first successful
5.569-second observation. Those observations include automation overhead and
sparse sampling. They are not cold-start measurements or a performance guarantee.
The owned app/windows were closed and private state cleaned afterward.

A later [installed52 Finder observation](qa/installed-finder52-2026-11-05.json)
verified folder-consent preselection, private-repository registration, repository
menus and cold Finder Commit delivery. It did not prove badges, every nested or
returned-volume grant, background refresh or full visual parity. Its owned windows,
repository permission and private preferences were restored afterward. Later source
fixes and their local checks do not silently update installed52. Current hosted,
installed and whole-port gates are tracked in [release blockers](RELEASE-BLOCKERS.md).
No public binary upload, notarization, App Store export or submission occurred.

## Signed local testing build53

[Build53's record](qa/signed-candidate53-2026-11-07.json) identifies a separately
packaged `0.1.0 (53)` candidate. Installed build52 remains unchanged.

| Item | Recorded identity |
| --- | --- |
| Exact clean source | `55fd1ca95ddfe8eca07654b0c96c0a6b84bed8cd` |
| Build-input SHA-256 | `bc4111547d96cdd25130a65ebda566e09a60e4bd48f1107815db41d2cb07e90c` |
| Local ZIP | `build/local-testing/TurtleGit-for-Mac-0.1.0-build53-signed/TurtleGit-for-Mac-0.1.0-build53-signed.zip` |
| ZIP SHA-256 | `505e6ee9559b54c3dc92ec82cdf83e7c487a390ec97bdb3ffba623a5cc5bb667` |
| Matching source archive SHA-256 | `e9c2f72638d0d2c9b84a0e7a9058748617d9f7bfcbde1e2b85b3c682bcfe4a47` |
| Signing channel | Apple Development, sandboxed AppStore configuration for local testing |

The candidate consolidates Commit message readiness, Browser/RefLog child
delivery, synchronization ownership, image rendering, Stash/Submodule recovery
and Push/Clone completion. Its one app build, repaired static audit and signed
Git/local-tool and twenty-image checks passed their recorded scopes. The initial
probe and packaging-consumer failures remain recorded separately; these are
cumulative results, not a fabricated single all-pass run. Test-consumer revisions
are pinned separately from the unchanged build source. Package copy/extraction
inventories and strict code-signing seals agree.

A private walkthrough of the actual signed app exercised Classic message edits,
selection and Amend, Git Gui-style double-click staging/unstaging, historical Log
selection and file comparison, local Push, local Clone and its Show Log handoff.
The app quit without a signal, but shutdown visibly waited on a large unrelated
Finder warm-cache merge. That performance issue remains open. Test preferences,
private repository/catalog/cache entries and launch routing were restored, and
the owned app and fixture were removed from the test session.

This package is not installed, notarized, uploaded or submitted to the Store.
Build53 Finder badges, a complete corrected-source hosted pass, older-platform
acceptance and full upstream dialog parity remain unproven. The package's
`Evidence` directory and manifest retain its narrower pre-walkthrough scope;
the linked checkpoint also records the later walkthrough and cleanup.

## Testing the local candidate

1. Open the installed application and check **About** for `0.1.0 (52)` before
   attributing a result to this candidate. **Build configuration: App Store**
   identifies its sandbox/runtime configuration; it does not mean it came from
   the Store. Keep the preserved build51 rollback separate from the installed app.
2. Start with a disposable repository or clone for operations that change Git
   state. Use native Open/Clone and authorize the requested folders. Linked
   worktrees, submodules and external object stores can require additional grants;
   [repository folder access](REPOSITORY-FOLDER-ACCESS.md) explains their scope.
3. Exercise Commit, staging, Log selection, Compare/Merge and cancellation in the
   workflows you use. Test Finder registration, menus and badges separately using
   [Finder integration](FINDER-SERVICES.md). A successful workspace operation does
   not establish that a Finder entry point or another repository has access.
4. Report the build, repository shape, entry point, exact steps and displayed
   diagnostic through the existing [Report Problem workflow](REPORT-PROBLEM.md).
   Distinguish installed52 from a later Debug/source build when reporting a fix.

This guide does not install or update the app automatically. A later candidate
needs its own measured source identity, package and testing record. Running a
focused source/native check cannot substitute for that candidate's installation
or a complete hosted run. The [local preview guide](LOCAL-PREVIEW.md) describes
the separate ad-hoc Release preview and its Finder/App Group limits.

## Matching source and runtime material

Keep each binary package with its exact source revision, build-input receipt,
LICENSE, NOTICE, dependency notices and runtime reconstruction material. The
repository archive and bundled runtime sources serve different scopes: an archive
of the TurtleGit checkout alone does not include every separately downloaded
runtime source archive. [Runtime layout](RUNTIME-LAYOUT.md) identifies their
packaged locations; the existing license/Store terms gate below remains unchanged.

For a new candidate, create the tracked-source archive from its accepted commit,
not from an unrelated current HEAD. Replace `EXACT_SOURCE_COMMIT` with that
accepted commit in this example:

```sh
git archive --format=tar.gz --prefix=TurtleGit-for-Mac-source/ \
  --output=/path/to/new/source-archive.tar.gz 'EXACT_SOURCE_COMMIT'
```

Use a fresh output path, retain the candidate's recorded dirty-input state when
applicable, and verify the resulting file list, contents and modes against that
accepted tree. A clean commit archive cannot represent uncommitted build inputs;
those inputs need their own recorded matching material. Preserve the original
runtime source archives, pins, patches, reconstruction scripts and notices with
the package as well. These provenance instructions do not establish license or
release-channel clearance.

## Build channels

| Channel | Configuration / scheme | Signing and use | Git engine |
| --- | --- | --- | --- |
| Source development | Debug / TurtleGitMac | Unsandboxed development; does not replace the installed candidate | Bundled engine if present, otherwise `/usr/bin/git` |
| Local Release preview / future direct distribution | Release / TurtleGitMac | Unsandboxed; the local preview script uses ad-hoc signing. A public direct release needs its own acceptance/signing path | Bundled engine if present, otherwise `/usr/bin/git` |
| Signed local testing, including installed52 | AppStore / TurtleGitAppStore | Apple Development local candidate; sandbox and saved user-selected folder grants | Prepared bundled engine required |
| Future Mac App Store distribution | AppStore / TurtleGitAppStore | Distribution identity/provisioning, terms review and Store acceptance remain open | Prepared bundled engine required; external fallback refused |

Prepare the complete pinned runtime set before a fresh Xcode distribution build.
The scripts retain their source/checksum and architecture requirements; see the
individual runtime guides for build-host prerequisites. The following unsigned
build prepares a candidate without signing, installing or publishing it:

```sh
python3 scripts/build-editorconfig-runtime.py
python3 scripts/build-issue-regex-runtime.py
python3 scripts/build-lexilla-runtime.py
python3 scripts/build-graph-layout-runtime.py
python3 scripts/build-metafile-runtime.py
python3 scripts/build-libgit2-runtime.py
python3 scripts/build-merge-diff-runtime.py
python3 scripts/build-openssh-runtime.py
python3 scripts/build-putty-runtime.py
python3 scripts/build-git-svn-runtime.py
python3 scripts/build-git-runtime.py
xcodebuild -project TurtleGitMac.xcodeproj -scheme TurtleGitAppStore \
  -configuration AppStore -destination 'generic/platform=macOS' \
  -derivedDataPath build-store CODE_SIGNING_ALLOWED=NO build
```

The `TurtleGitAppStore` scheme uses the AppStore configuration for Run, Test,
Profile, Analyze and Archive. This keeps those actions on the same sandbox and
bundled-runtime configuration; selecting the scheme does not sign or submit a
product. Build tasks still use the configuration explicitly requested by the
command.

### Shared version and offline build identity

The XcodeGen project defines marketing version `0.1.0` and default build `2` once
at the shared settings level. App, Finder extension and cache service Info.plists
use `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`, so all three peers
receive the same values. The installed52 candidate used an explicit build-number
override; the project default is not the current installed build. Their measured
bundle identifiers must also retain the application's `.finder` and `.cache`
relationship.

Both `build-distribution.py` and `archive-distribution.py` accept optional
`--build-number` and `--jobs` arguments. For example, `--build-number 2 --jobs 4`
requests build 2 with at most four concurrent Xcode tasks. Omitting the build
number uses the project's current setting. A requested build number contains one
to three numeric components separated by periods; it is passed to Xcode and then
compared with the actual built bundle metadata. It does not edit an existing
candidate, query App Store Connect or establish that a number is newer than any
uploaded build.

Audit reports distinguish `requested_build_number`, `audit_requested_build_number`
and `measured_identity`. The measured identity includes the application and both
peers, and all marketing versions and build numbers must agree. A missing,
mismatched or differently measured value fails the audit. `--audit-existing`
retains the original build request and records any requested identity check for
that audit separately. The reports also retain the build's `build_jobs` value.
These are offline provenance checks, separate from provisioning, signing and
release-channel acceptance.

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
python3 scripts/build-distribution.py --configuration AppStore --derived-data build-store \
  --build-number 2 --jobs 4
```

Use `--configuration Release` for a future direct-distribution candidate, or
`--audit-existing` to recheck a candidate with its original complete audit without another build. A raw Xcode build alone does not establish the measured input provenance.
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

## Candidate provenance and preview freshness

Distribution audits use `TurtleGitDistributionInputsV3`, a fingerprint of
repository build inputs measured before and after the build. The complete path
closure is `Sources`, `FinderSync`, `Configuration`, `TurtleGitMac.xcodeproj`, `Package.swift`,
`Package.resolved`, `project.yml`, `LICENSE`, `NOTICE`, `Licenses`, `patches` and
`scripts`. This includes runtime reconstruction patches, third-party license
texts and the XcodeGen recipe alongside generated project files, source and pins.
The top-level `FinderSync` directory contains the compiled Finder extension;
changing its menus or badges must invalidate the candidate just like app code.
Tracked/untracked files, deletions, modes and contained file aliases are measured.
V1 records omitted runtime reconstruction inputs; V2 also omitted the compiled
Finder extension directory. Both require rebuilding and cannot be silently
upgraded by auditing their existing bundles.

HEAD at measurement and dirty input state remain explicit. A candidate built from
an earlier HEAD with measured dirty configuration/script inputs must not be
labelled a clean build of a later documentation commit. This is a bounded input
check, not a claim of a hermetic or bit-reproducible build.

The app audit inventories every candidate bundle file, mode and portable alias;
the archive audit includes its products and matching dSYMs. Both retain the
measured build inputs.
`--audit-existing` requires its original complete audit and unchanged measured
inputs/bundle; legacy executable-only audits require one rebuild. Local preview
packaging refuses stale inputs or any changed bundle resource before copying,
checks the unsigned copy before signing, and compares the signed app against its
extracted ZIP. It rechecks the source candidate before publishing the fresh output
directory. The preview manifest retains the build revision, input fingerprint,
dirty state and signed bundle inventory. It does not claim signing, sandbox or
App Store acceptance from those hashes.

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
uses the macOS `$(TeamIdentifierPrefix)org.turtlegit.macos` format. The app,
Finder extension and cache service receive that same team-qualified entitlement;
the launch-agent Mach service uses the corresponding `.cache` suffix. Runtime
identity comes from the actual signing team, and unsigned processes refuse
container access. See the [signed Finder development guide](SIGNED-FINDER-DEVELOPMENT.md).

The main app's AppStore configuration declares the following capabilities in
`Configuration/AppStore.entitlements`:

- `com.apple.security.app-sandbox`.
- `com.apple.security.files.user-selected.read-write` and
  `com.apple.security.files.bookmarks.app-scope` for selected files/folders and
  persistent app-owned access.
- `com.apple.security.network.client` and `com.apple.security.network.server`.
  Both network capabilities are currently declared; their necessity and scope
  must be included in distribution review.
- `com.apple.security.application-groups`, containing the team-qualified
  `org.turtlegit.macos` group shared with Finder and the cache service.
- `com.apple.security.automation.apple-events` and
  `com.apple.security.temporary-exception.apple-events` for the declared Office
  targets `com.microsoft.Word`, `com.microsoft.Excel` and
  `com.microsoft.Powerpoint`, used by Office comparison integrations.
- `com.apple.security.scripting-targets`, declaring the `com.apple.mail.compose`
  scripting access group on `com.apple.mail` for Mail composition.

The Finder extension declares sandbox and the shared group in
`Configuration/Finder.entitlements`. The cache service additionally declares
app-scoped bookmarks in `Configuration/Cache.entitlements`. These are distinct
peer entitlement sets, not a copy of every main-app capability. Declared
entitlements do not establish user consent, successful automation or App Review
acceptance; the Office exceptions and all requested capabilities remain part of
the distribution review.

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
are included. Git-SVN has its own packaged Perl/runtime reconstruction path; see
[Git-SVN runtime](GIT-SVN-RUNTIME.md). This does not imply every upstream
Perl/Python companion or git-gui/gitk is supplied. The compatible helper lookup
alias is:

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

The initial October 4 universal-runtime results and their original unverified
scope are preserved in [checkpoint history](history/DISTRIBUTION-CHECKPOINTS.md#runtime-build-evidence).
Use the current installed52 receipt above and the individual runtime guides for
later candidate-specific evidence; an older packaging pass does not certify the
current app, every Git workflow or a distribution channel.

## GPL and App Store terms — unresolved release gate

The project remains GPL v2, matching the upstream license in `LICENSE`. Rewriting
windows in Swift does not remove licensing obligations for a derived port.
No upstream licensing exception or permission has been obtained.

GPL v2 section 6 prohibits imposing additional restrictions on recipients. Apple's
[current standard application EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/)
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

### Terms review worksheet — October 31, 2026

| Primary source | Observed requirement | Decision still needed |
| --- | --- | --- |
| [Apple custom EULA setup](https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement) | Connect accepts a plain-text custom agreement for selected territories; otherwise the standard agreement applies. | Record exact proposed text and territories. The configuration option itself does not establish GPL compatibility. |
| [Apple minimum custom EULA terms](https://www.apple.com/legal/internet-services/itunes/dev/minterms/), sections 2 and 8 | License scope includes nontransferable use on owned or controlled Apple products under Usage Rules; developer contact particulars are required. | Resolve that scope against GPL section 6 and verify the final publisher contact particulars. |
| [Apple standard EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/), section a | Usage/redistribution restrictions coexist with an open-source exception to specified copying/modification restrictions. | Review the complete proposed arrangement; do not assume that exception settles every restriction. |
| [Project GPL](../LICENSE), sections 3 and 6 | Corresponding-source obligations and recipients' rights remain applicable. | Match the exact distributed code/assets/dependencies to source, notices, reconstruction inputs and any necessary permissions. |

This worksheet records questions for the distribution review, not a replacement
license or a clearance decision. No custom EULA has been entered in Connect and
no application has been submitted. Local testing proceeds independently.

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
Mail requests no temporary Apple Events exception or inbox access group; the
separate Word comparison target is documented below. Signed TCC
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
  --archive-path build/artifacts/TurtleGitMac-AppStore.xcarchive \
  --build-number 2 --jobs 4
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

The [October 14 unsigned archive checkpoint](history/DISTRIBUTION-CHECKPOINTS.md#october-14-unsigned-archive-checkpoint)
retains its exact artifact path, UUID/inventory evidence and initial fixture
repairs. That historical candidate does not establish acceptance of a later
archive, signed export or Store submission.

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

## Microsoft Word comparison Automation target

The Word document-diff adapter adds a `com.microsoft.Word` Apple-event temporary
exception to AppStore preparation. The inspected Word scripting dictionary has no
access groups; Apple's target-specific temporary-exception mechanism is used
instead. Apple Mail retains its compose-only scripting target. The package audit
allows only the explicit Word, Excel and PowerPoint targets (see below) and refuses unexpected/suffixed Apple-event keys.
The usage description covers both operations. Provide the exception's comparison
use case with the eventual App Store submission; no Apple acceptance is claimed.
See [Word comparison](WORD-COMPARISON.md) for failure/permission/worker ownership
and remaining actual Word and signed sandbox acceptance.

## Excel comparison Automation target

The Excel adapter adds `com.microsoft.Excel` to the same target-specific AppStore
Apple-event exception used for Word. Both inspected Office dictionaries lack
scripting access groups. The audit permits exactly those two targets, preserves
Mail's compose-only group, and rejects unexpected/suffixed exception keys. The
usage description now covers workbook comparison as well. Actual Excel/TCC/file
grants, signed sandbox execution and eventual exception-review acceptance remain
open; see [Excel comparison](EXCEL-COMPARISON.md).

## PowerPoint export Automation target

Presentation comparison adds the exact installed bundle identifier
`com.microsoft.Powerpoint` to the AppStore preparation allowlist. The inspected
PowerPoint dictionary provides no scripting-access groups for this workflow. The
usage description includes selected-presentation export for native review.
`validate-app-bundle.py` checks the three exact Office targets and continues to
refuse unexpected or suffixed exception keys. This configuration does not prove
Apple approval or successful signed cross-application file grants. Live export,
TCC, protected-document prompts, macro-policy restoration and installed sandbox
acceptance remain separate checks. See [presentation comparison](POWERPOINT-COMPARISON.md).


## Build configuration and optional Store listing

The `AppStore` configuration determines sandbox/runtime policy. It does not prove
publication, a Store receipt, a purchasable listing or Store-managed updates for a
locally installed Apple Development build. About labels this **Build configuration:
App Store**. There is currently no configured Store listing: About's
**View in App Store…** is disabled, and Check for Updates explains the unavailable
listing without opening a generic Store application, fetching GitHub releases or
downloading a replacement for the sandboxed candidate. Desktop builds retain their
existing GitHub release checks and verified download workflow.

When the publisher has an actual public listing, its reviewed bundle Info.plist
may provide the optional `TurtleGitAppStoreListingURL` string. Use the canonical
HTTPS page `https://apps.apple.com/app/id<assigned-id>` (optionally a two-letter
country path and app slug). Validation rejects other hosts/schemes, userinfo,
ports, query/fragment payloads, encoded path components and invalid ID paths. No
placeholder/fake Store ID or default listing is shipped. The configured page is
opened exactly; its existence and publication status remain the publisher's
responsibility. The app does not infer publication from its build flag.

The connected utility-owner registry preserves existing About, Settings and
update-review owners through minimized, deliberate presentation and accepted
Settings replay gaps. A quiet/automatic background update check without a window
does not suppress an explicit workspace reopen; a forced pending presentation
retains its intent until completion/cancellation. Reopen focuses an existing utility or retains its pending owner rather than
creating a repository workspace. Installed52 includes the earlier utility-owner continuation;
the scoped signed45 observations remain in [checkpoint history](history/DISTRIBUTION-CHECKPOINTS.md#historical-installed-signed-local-testing-build45). Complete current
hosted and wider physical acceptance remain separate.


## Historical distribution checkpoints

The [checkpoint history](history/DISTRIBUTION-CHECKPOINTS.md) retains the complete
dated journal and evidence. These headings preserve previous section targets;
their installation statements describe those dates, not the current candidate.

### Installed signed local testing build49

[Historical evidence and scope](history/DISTRIBUTION-CHECKPOINTS.md#installed-signed-local-testing-build49).

### Historical installed signed local testing build47

[Historical evidence and scope](history/DISTRIBUTION-CHECKPOINTS.md#historical-installed-signed-local-testing-build47).

### Historical installed signed local testing build46

[Historical evidence and scope](history/DISTRIBUTION-CHECKPOINTS.md#historical-installed-signed-local-testing-build46).

### Historical installed signed local testing build45

[Historical evidence and scope](history/DISTRIBUTION-CHECKPOINTS.md#historical-installed-signed-local-testing-build45).

### Historical installed signed local testing build41

[Historical evidence and scope](history/DISTRIBUTION-CHECKPOINTS.md#historical-installed-signed-local-testing-build41).

### Historical prepared signed local testing build40

[Historical evidence and scope](history/DISTRIBUTION-CHECKPOINTS.md#historical-prepared-signed-local-testing-build40).

### Historical local testing build33

[Historical evidence and scope](history/DISTRIBUTION-CHECKPOINTS.md#historical-local-testing-build33).

### Historical installed checkpoint — 29 October 2026

[Historical evidence and scope](history/DISTRIBUTION-CHECKPOINTS.md#historical-installed-checkpoint--29-october-2026).

### Historical measured local artifacts — 23 October 2026

[Historical evidence and scope](history/DISTRIBUTION-CHECKPOINTS.md#historical-measured-local-artifacts--23-october-2026).

### Historical signed development evidence

[Historical evidence and scope](history/DISTRIBUTION-CHECKPOINTS.md#historical-signed-development-evidence).

### October 24 signed development candidate

[Historical evidence and scope](history/DISTRIBUTION-CHECKPOINTS.md#october-24-signed-development-candidate).

### October 25 signed consolidation and installed Finder check

[Historical evidence and scope](history/DISTRIBUTION-CHECKPOINTS.md#october-25-signed-consolidation-and-installed-finder-check).

### Historical installed build 13 — 26 October 2026

[Historical evidence and scope](history/DISTRIBUTION-CHECKPOINTS.md#historical-installed-build-13--26-october-2026).

### October 26 installed build 12 — historical

[Historical evidence and scope](history/DISTRIBUTION-CHECKPOINTS.md#october-26-installed-build-12--historical).

### October 26 installed build 11

[Historical evidence and scope](history/DISTRIBUTION-CHECKPOINTS.md#october-26-installed-build-11).
