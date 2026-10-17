# Trying the local preview

TurtleGit for Mac is a macOS fork of TortoiseGit. The full port and App Store
release remain in progress. A local preview packages the implemented application
and its Git/helpers so it can be tried without a terminal Git installation.

## Open the app

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

The local preview has an ad-hoc code seal. It has no authorized developer-team
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

The current hosted wrapped-navigation check times out on macOS 15.7.9 Intel.
A hash-verified stack sample is retained in [the CI evidence](qa/ci-wrapped-stack-2026-10-18.json).
The preview contains the corresponding inspected editor source; the exact trigger
and repair remain unproven. Successful packaging does not clear that issue.

The 18 October local package is under `build/previews/TurtleGit-2026-10-18`.
Its ZIP is `TurtleGit-for-Mac-0.1.0-local-preview.zip`; the adjacent manifest
records application source `ae48b26a`, measured dirty script inputs and the actual
checksum. The [packaging evidence](qa/distribution-current-preview-2026-10-18.json)
also records the separate unsigned AppStore archive. These local artifacts have
not been uploaded as a GitHub release.
