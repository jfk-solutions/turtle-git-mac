# Trying TurtleGit locally

TurtleGit for Mac is a macOS fork of TortoiseGit. Its local builds include Git
and runtime helpers. The team-signed development app supports Finder integration;
the ad-hoc archive is a separate channel.

## Team-signed development app

On the development Mac, open **TurtleGit for Mac** from Applications. Check its
version and build in **About TurtleGit** before reporting a problem. The latest
measured installation and its verification scope are recorded in
[release checkpoints](RELEASE-BLOCKERS.md). Follow the
[signed development guide](SIGNED-FINDER-DEVELOPMENT.md) for building and enabling
the Finder extension.

Try a disposable repository first: Classic Commit, the staging workspace, Log,
comparison, patch documents and Finder registration/badges. Cancel a dialog when
you only want to inspect it. Include the workflow, expected and actual results,
macOS version and About build number in a bug report. Keep credentials and private
repository contents out of screenshots.

This is a local development build, not a published Mac App Store product or a
notarized Developer ID download. Store submission follows owner testing.

## Ad-hoc archive

The preview directory contains `TurtleGitMac.app`, a ZIP, `SHA256SUMS`, `LICENSE`,
`NOTICE`, installation notes and a measured build manifest. Use the app directly
or extract the ZIP. Keep your existing installation separate if you want to retain
it; the packaging command does not replace or launch it.

Open the app and choose a repository folder. Start with a disposable repository
when assessing workflows that modify files or history. The [getting started guide](GETTING-STARTED.md)
explains checked-file Commit, optional staging, Log, comparison and recovery.
[The dialog guide](DIALOG-GUIDE.md) links the implemented windows and their limits.
Windows-only hook scripts, external Git helpers and Office/LibreOffice integrations
can require their corresponding macOS programs or settings.

The archive contains Apple Silicon and Intel slices and packaged runtime helpers.
Architecture inspection is separate from execution on an actual Intel Mac or the
minimum supported macOS release. Local build checks do not certify every workflow.

## Finder needs the signed development channel

The ad-hoc archive has a local code seal. It has no authorized developer-team
App Group, so it cannot share status and menu data with the Finder extension or
independent cache service. Enabling the extension alone does not grant that access.
The app's repository and dialog workflows remain available.

To assess Finder integration, use a properly team-signed candidate and follow
[the signed development guide](SIGNED-FINDER-DEVELOPMENT.md) and
[Finder service deployment](FINDER-SERVICE-DEPLOYMENT.md). The installed development
checkpoint records the activation, badges and selected command routes that were
actually exercised. It does not certify every command, volume or signed version.

An ad-hoc preview is not Developer ID signed or notarized, and is not an App Store
submission. macOS can require explicit approval to open it. The separate unsigned
App Store archive supplies build products and matching debug symbols for later
signing; it does not establish signed runtime or App Review acceptance.

## Know which source was packaged

`preview-manifest.json` retains the measured build revision, source input hash,
dirty-input state, complete signed bundle inventory and ZIP checksum. A later
documentation commit does not relabel the original build revision. Dirty input
state remains explicit even when the changed input is a development script.
The archive has its own adjacent audit report and optional offline export settings.

The package includes the original licenses/notices and reconstruction material for
its pinned runtimes. See [distribution engineering](DISTRIBUTION.md),
[privacy](PRIVACY.md) and [release blockers](RELEASE-BLOCKERS.md) for scope and
remaining work. Nothing is installed, registered, uploaded or submitted by local
packaging. The website's screenshots are actual native captures from their dated
workflow checks; each parity guide records the remaining acceptance.

## Historical ad-hoc package — 23 October 2026

The local package is `build/previews/TurtleGit-2ba5f945-build3/`. Its app, Finder
extension and cache service all report version `0.1.0`, build `3`. The ZIP is
`TurtleGit-for-Mac-0.1.0-local-preview.zip` (**409,567,553 bytes**), SHA-256:

```text
257250e35136e059e68ce29d7cacfa4844dac24ede3207b94a876b4f5e88a371
```

The adjacent manifest records measured build HEAD
`2ba5f94555f059c2a3fab888ace15fe808fe2105` and V3 source input SHA-256
`df66a7af80dbb33925e718f495a2b131127f5cf075a8bd395b3876830672fd6d`.
Its dirty input state includes the selected-file dragging/provenance fixes and existing
protected development-script changes. It is not a clean-commit build claim.
The app and extracted ZIP pass matching complete 6,354-member signed inventories
and deep strict ad-hoc code-seal checks.

[The delivery evidence](qa/distribution-2ba5f945-build3-2026-10-23.json) also records
the separate unsigned AppStore archive, eight universal app-owned components and
eight matching universal dSYMs. Packaged WCRev `--json` passed under arm64 and
x86_64/Rosetta against the expected private repository HEAD and branch; both owned
receivers were reaped. This did not launch the shipping main GUI, install or
register Finder, refresh the signed candidate, upload a GitHub release, or export
or submit an App Store build.

The [2ba5f945 hosted macOS run](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/39978977077)
was pending at the October 23 observation while cb676f1a was active. A complete hosted pass remains
required; these package and scoped helper checks do not clear that gate. The
[release blockers](RELEASE-BLOCKERS.md) distinguish earlier hosted failures and
local repairs from the current delivery evidence. The
[October 18 package record](qa/distribution-16380893-2026-10-18.json) and
[earlier ae48b26a record](qa/distribution-current-preview-2026-10-18.json) remain
historical evidence.
