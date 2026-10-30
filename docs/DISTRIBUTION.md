# Distributing TurtleGit for Mac

*A macOS fork of TortoiseGit*

The Mac App Store is a target distribution channel, not a verified release path.
The full port, signed runtime tests and licensing clearance remain incomplete.
Development builds can use the installed Git executable. The App Store
configuration requires a prepared pinned runtime and refuses external fallback.

## Prepared signed local testing build40

[Signed build40](qa/signed-consolidation-build40-2026-10-30.json), `0.1.0 (40)`,
is packaged from clean source `3ef55703`. Its universal build, strict code seals,
frozen inputs, 96 bundled Help source members and 6,382-member ZIP round trip
pass. A disposable signed sandbox parent executes packaged Git and 19 metafile
cases, including eight exact Windows HALFTONE pixels. All observed helpers and
probe parents drained without forced cleanup. These checks do not exercise the
shipping GUI or physical Finder integration.

The local package is `TurtleGit-for-Mac-0.1.0-build40-signed.zip`, SHA-256
`6bfc1ac06e25c83beb8facffe0793c997dba86eb3d16f2afa07692a18f1e5670`.
It has not been installed or publicly uploaded. Installed build39 and the system's
TurtleGit application/URL resolution remain unchanged. The package is for local
Apple Development testing; it is not notarized or submitted to the App Store.
Current-source hosted CI and final acceptance remain open.

## Historical local testing build33

[Signed build33](qa/signed-consolidation-build33-2026-10-29.json), version
`0.1.0 (33)`, was built from clean source `4daef1a3`. It includes the three Unified
Diff navigation/editing batches and leading-scalar codec repairs. The unchanged
source-input audit, strict signatures, eight app-owned arm64/x86_64 components,
packaged Help and signature-preserving ZIP extraction/inventory checks pass.
A focused signed-parent check executes the actual production Core framework's
new navigation, selection/byte and BOM/NFD paths under the sandbox; it does not
exercise the shipping AppKit editor or NSUndoManager.

The local package is `TurtleGit-for-Mac-0.1.0-build33-signed.zip` (SHA-256
`e3a7ee07c20243747de3f07e9d8b851aaa0deb5bdef9bcd5721e6e15927818ff`).
It is a local Apple Development testing artifact, not a public release download.
[Build33 was installed and reopened with user approval](qa/signed33-installed-2026-10-29.json).
The complete installed inventory matches the candidate and its strict signature
passes. The original app exited after a delayed normal quit; no signal was sent.
Build32 is preserved for rollback. Finder/Dock were not restarted and no
repository-permission change, App Store upload or notarization was performed.
The workspace was visually confirmed; physical installed workflows,
Intel/minimum-macOS execution, complete hosted CI and full-port acceptance remain
separate.

## Historical installed checkpoint — 29 October 2026

[Signed build32](qa/signed-consolidation-build32-2026-10-29.json), version
`0.1.0 (32)`, was installed from clean source `144fdf78`. It adds retained-byte
Blame encoding, Finder returned-volume recovery and metafile canvas/source-alpha
corrections. All eight app-owned components contain arm64 and x86_64; measured
inputs, strict signatures and the complete installed inventory pass. The focused
signed-parent Metafile check passed, including captured Windows alpha samples.
With user approval, TurtleGit quit normally, was replaced and reopened to its
workspace. Build31 is preserved for rollback. This does not establish physical
Intel execution, every installed workflow, physical Finder badges or a complete
hosted CI pass. No App Store submission or notarization was made.

The older dated artifacts below remain historical evidence, not the current
package to install or a certification of later source.

## Historical measured local artifacts — 23 October 2026

The Release preview and unsigned AppStore archive are version `0.1.0`, build `3`.
Application, Finder extension and cache service versions/builds agree. Their
measured build HEAD is `2ba5f94555f059c2a3fab888ace15fe808fe2105`, with V3 input
SHA-256 `df66a7af80dbb33925e718f495a2b131127f5cf075a8bd395b3876830672fd6d`.
The input state is **dirty**: it includes the selected-file dragging and provenance-script
fixes and existing protected development-script work. These artifacts are not
claimed to be a clean build of that commit or a later documentation commit.
[The dated delivery evidence](qa/distribution-2ba5f945-build3-2026-10-23.json)
records the actual reports, diagnostics and probes.

- Preview: `build/previews/TurtleGit-2ba5f945-build3/`, containing
  `TurtleGitMac.app`, `TurtleGit-for-Mac-0.1.0-local-preview.zip`, `SHA256SUMS`,
  notices, installation notes and `preview-manifest.json`. The ZIP is
  **409,567,553 bytes**, SHA-256
  `257250e35136e059e68ce29d7cacfa4844dac24ede3207b94a876b4f5e88a371`.
  Its 6,354-member signed bundle inventory matches the extracted ZIP, and both
  deep strict ad-hoc code-seal checks pass.
- Release source audit: `build/preview-2026-10-15/distribution-audit.json`.
  The directory name is historical; the report describes that dated build.
  Its application inventory has 6,349 members and eight app-owned universal
  components. Release build/audit commands exited zero.
- Archive: `build/archives/TurtleGit-AppStore-2ba5f945-build3.xcarchive`, with
  adjacent `.archive-audit.json` and `.ExportOptions.plist`. Eight app-owned
  components and all eight matching dSYMs contain arm64 and x86_64; its complete
  archive inventory has 6,382 members. The unsigned archive and audits passed.
  Three contradictory “failed with exit code 0” diagnostics in the archive build
  log remain recorded despite the successful process exit and audits; the log
  is not described as error-free.

Packaged WCRev `--json` returned the expected private repository HEAD and branch
under arm64 and x86_64/Rosetta. Both owned receivers were reaped. Rosetta execution
does not certify a physical Intel Mac or minimum supported macOS. This checkpoint
did not launch the shipping main GUI, install an app, register Finder/cache
services, refresh the signed development candidate, upload a release or export or
submit an App Store build. [Trying the preview](LOCAL-PREVIEW.md) explains why the
ad-hoc preview cannot access the authorized Finder App Group.

### Historical signed development evidence

The separately refreshed October 19 Apple Development candidate at
`build/signed-development/Build/Products/AppStore/TurtleGitMac.app` used measured
`bfa1fafe` inputs. Its peer signatures/groups, eight universal components,
205-item runtime layout, branding, complete seal and selected sandboxed-parent
Git/Lexilla/Metafile/App Group probes passed. Its 6,302-member inventory remained
unchanged. See [signed execution](SIGNED-FINDER-DEVELOPMENT.md#october-19-signed-runtime-checkpoint-historical)
and [dated evidence](qa/signed-metafile-2026-10-19.json). That older candidate is
not this unsigned archive and was not refreshed by the October 23 delivery batch.
The [October 18 preview/archive record](qa/distribution-16380893-2026-10-18.json)
also remains historical evidence.

The [2ba5f945 macOS run39978977077](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/39978977077)
was pending at the October 23 observation while the older cb676f1a run was active. Packaging and the scoped local
checks do not establish a complete hosted pass. [Current blockers](RELEASE-BLOCKERS.md)
retain earlier failed assertions, local repairs and the remaining signed,
installed and full-port acceptance work separately.

## October 24 signed development candidate

The October 24 local Apple Development checkpoint at
`build/signed-development/Build/Products/AppStore/TurtleGitMac.app` used
measured `9a8e37ce` inputs, version `0.1.0`, build `2`. App, Finder extension and
cache service identities agree. Its eight application components are universal,
its runtime layout contains 206 code items, and its complete 6,356-member bundle
inventory remained unchanged through the signed checks.

Six disposable sandbox processes passed App Group writer/reader, denied
nonmember, history/Notes, selected metafile and cleanup checks. The history check
uses actual packaged Git and libgit2 to preserve typed references and historical
Browser/gitlink content, and save exact large and empty Notes with configured
signatures. All owned receivers and observed helpers were reaped; the installed
app and Finder extension were left untouched. See the
[dated checkpoint](qa/signed-history-family-2026-10-24.json).

The record keeps the dirty build-input signature and the later external
validation-runner correction separate; every other measured input and the probe
source remained unchanged. Five contradictory exit-zero compiler diagnostics
remain recorded despite the build's successful exit. No Core suite or native
editor group was repeated for this sandbox-only checkpoint. The October 23 ZIP
and unsigned archive above remain separate older artifacts. This check does not
establish installed shipping-GUI/Finder acceptance, external repository grants,
distribution signing, archive export or App Store submission.

## October 25 signed consolidation and installed Finder check

The [dated receipt](qa/signed-consolidation-2026-10-25.json) records a universal
Apple Development AppStore build from measured `5b315808` inputs, followed by
strict signatures/layout checks and six disposable signed sandbox cases. Its
6,356-member bundle inventory matched the installed app exactly. The previous
installed bundle was retained for recovery. Existing signing profiles were used
without requesting provisioning updates.

The actual installed app accepted an external repository through its real folder
chooser, loaded status without changing index bytes, displayed native Remote
rows, and closed Settings through Cancel and OK. Finder's file menu reopened the
app into file-scoped Log, with graph and Notes. Saving a Note succeeded through
the signed GUI. After normal app Quit, the background helper alone updated a
private folder badge Normal → Modified → Normal. The private watch and saved
permission were removed; the original repository/watch IDs were retained and the
background setting restored. Owned main/cache processes were absent at cleanup.

This receipt predates the subsequent macOS 27 menu-image and first-use Finder
registration batch. It does not establish their acceptance, a full hosted CI
pass, every dialog's appearance, Intel execution, distribution signing or an App
Store export/submission. The compiler warnings remain recorded. Earlier preview
ZIPs and unsigned archive receipts remain separate artifacts.

## Historical installed build 13 — 26 October 2026

The [build13 receipt](qa/signed-consolidation-build13-2026-10-26.json) records
version `0.1.0`, build `13`, from clean source `a3a38c07`. Its measured input
SHA-256 is `7a267fbc242f37f85b512ff7c3ec951f19e79b7f8068e87470426434494f9fa0`;
the application executable SHA-256 is
`689e6ec01473f0d240bfbd8c4630efb497789fd7417c4ef7a99783be3f781a5c`.
The Apple Development build uses team `A49SCA5S8K`. Strict deep seals, matching
sandbox/App Group identities, eight universal app-owned components and inherited
Git/libgit2/metafile checks pass. Candidate, staged and installed inventories
match across all 6,362 members. The installed app is
`/Applications/TurtleGit for Mac.app`; build12 remains recoverable at
`build/qa/signed13-displaced-installed-2026-10-26`.

The first build stopped with exit65 after rejecting a stale Metafile helper
cache. Only the current helper was rebuilt; the incremental app build then
finished with exit0 without recompiling native application sources. No
contradictory exit-zero compiler diagnostics were recorded. These earlier
failure and recovery receipts remain part of the evidence.

The initial signed runtime group passed its writer, reader and denied-access
assertions, but failed because its process observer missed a short-lived
libgit2 child. It stopped before the image phase. A deterministic valid Notes-read
stdin handshake with exact PID/PGID acknowledgement repaired that observer;
the scoped history and 17-image retry passed (14 positive and three refusal
cases, including Johab native-font fallback coverage `1.0`). Observed helper and
receiver processes and groups drained. No Core suite or full integration suite
was repeated for this signed checkpoint.

Build13 packages the newer [Blame toolbar placement](BLAME-TOOLBAR-PLACEMENT-PARITY.md),
[WMF text](METAFILE-WMF-TEXT-PARITY.md) and
[Bitmap16 transfer](METAFILE-WMF-BITMAP16-PARITY.md) implementations. Packaging
and selected signed runtime/image cases do not certify every toolbar gesture,
metafile record or Windows rendering result.

The installed workspace and its native Open Repository chooser were visible;
the exact private Harbor repository was selected. After Open Repository, CUA
accessibility, screenshot and rebind requests timed out. Sampling the main
process showed an idle AppKit event loop; no app-hang or fresh workflow-screenshot
claim follows. The owned main process was terminated. The private sample's HEAD,
semantic index and file bytes remained unchanged. Its one temporary grant was
removed; the original two grant IDs, paths and bookmarks remain, retaining their
current recency metadata and order. No main process was present before this check,
so no headless instance was restored. The exact private cache subtree was removed
through the production store API; dead publication leases were pruned. All 24
recorded receiver/helper/main PIDs were independently absent, and the selected
UI preferences were unchanged.

Finder registration reports one enabled extension, UUID
`6FF13B4A-EC5B-4049-8F81-42E82EC24275`. The preexisting Finder process was left
untouched: no Finder restart or global reset was performed. Registration does
not establish physical badge/menu acceptance. At the recorded observation,
Pages for `a3a38c07` passed and its macOS workflow was pending; a complete current
hosted result remains open. Physical pointer/palette/keyboard/VoiceOver,
multiple-display and Finder behavior, Intel/minimum-OS execution, full parity,
distribution signing and App Store acceptance remain separate gates. No
application export, upload or App Store submission was performed.

## October 26 installed build 12 — historical

The [build12 receipt](qa/signed-consolidation-build12-2026-10-26.json) measures
clean source `37b84cd1`, including dialog reactivation and utility Close. The
Apple Development candidate passed strict seals, matching sandbox/App Group
identities, eight universal components and equal 6,362-member inventories before
and after installation. The build completed without contradictory zero-exit
compiler diagnostics. Build11 remains recoverable.

Installed About showed version12 and the actual bundled Git version. Repeated
activation retained About alone in the native Window menu. Commit's permission
chooser was exercised on a synthetic repository, but UI automation timed out
after authorization and on a cold retry. No fresh Commit screenshot or app-hang
claim follows from that failure. Exact process cleanup, private-grant removal,
unchanged sample Git/file data and restoration of the headless Finder watcher
are recorded. Original grants remain; their updated recency metadata is retained.
Physical Finder, wider dialog/keyboard checks, refreshed workflow screenshots,
full hosted integration and App Store distribution acceptance remain open.

## October 26 installed build 11

The [build 11 receipt](qa/signed-consolidation-build11-2026-10-26.json) binds the
installed Apple Development AppStore-configuration app to `77f0f4f9`, 1,510
measured inputs and matching 6,362-member candidate/staged/installed inventories.
All eight app components are universal and strict signatures pass. Six disposable
signed-parent sandbox cases pass actual bundled Git/libgit2/metafile execution;
the unsigned-only validator's direct inherited-helper launch failure is retained
as an inapplicable check, not relabeled as a passing runtime test.

Installed Working Tree, Commit and About were reviewed using a disposable
repository. Its HEAD, semantic index and file bytes were preserved, its temporary
permission was removed, and the original saved repositories remain. Build 10 is
preserved for recovery. The former headless Finder-watch service is restored as
one main instance; no background preference or global cache was reset.

This is a development-signed installation, not a distribution export or App Store
submission. Physical Finder badges/menus, tooltip hover, workspace/reopen isolation,
Intel execution and a complete current hosted result remain separate gates.

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
python3 scripts/build-metafile-runtime.py
python3 scripts/build-openssh-runtime.py
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

The XcodeGen project defines marketing version `0.1.0` and current build `2` once
at the shared settings level. App, Finder extension and cache service Info.plists
use `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`, so all three peers
receive the same values. Their measured bundle identifiers must also retain the
application's `.finder` and `.cache` relationship.

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
