# Production runtime layout

TurtleGit separates runtime code from data before Xcode signs the application.
The public helper lookup paths remain compatible with existing Git, SSH,
syntax-highlighting, merge and graph integrations.

| Payload | Physical location |
| --- | --- |
| Native command-line executables | `Contents/MacOS/TurtleGitRuntime-*` |
| Native runtime libraries and Perl extension bundles | `Contents/Frameworks/TurtleGitRuntimeLibraries/` |
| Scripts, configuration, templates, modules, licenses and reconstruction sources | `Contents/Resources/TurtleGitRuntimes/<runtime>/` |
| Runtime layout and code provenance | `Contents/Resources/runtime-layout.json` |

`Contents/Helpers/<runtime>` links to the corresponding resource tree. Native
files in that tree link to their actual executable/library locations. Existing
internal library aliases remain relative links. The finalizer resolves original
load paths before moving code, assigns unique destinations, changes private
library references to `@rpath`, and signs each native payload. The AppStore
configuration gives executable children the inherited sandbox entitlements;
libraries do not receive executable sandbox entitlements.

The Git-SVN dispatcher locates packaged modules relative to `Contents/MacOS`,
while standalone reconstruction builds use the original git-core layout. It
sets bundled Git/Perl search paths explicitly. The merge adapter continues to
load the library through the public runtime alias.

The bundle audit checks descriptor hashes, code placement, signatures, every
native dependency and architecture, and resource-tree containment. It rejects
undeclared links, resource files containing native code, unowned destinations,
and partial runtime refreshes. Individual payload validators retain their
source, license, deployment-target and behavior checks. Installed SVN manifests
retain original file hashes alongside updated relocated hashes.

Production builds and cache misses replace helper aliases with fresh runtime
trees before finalization. Re-running finalization on an unchanged complete bundle audits it
without deleting live code. A partially refreshed bundle must be rebuilt fully.

This layout follows Apple's [Embedding nonstandard code structures in a bundle](https://developer.apple.com/documentation/xcode/embedding-nonstandard-code-structures-in-a-bundle)
and [macOS code-signing guidance](https://developer.apple.com/library/archive/technotes/tn2206/).
Ad-hoc signature checks do not prove App Store identity, provisioning, sandbox
execution, Finder activation, launch-service registration or licensing clearance.
The [2026-10-13 batch record](qa/runtime-layout-2026-10-13.json) records passing
Debug and unsigned AppStore builds, bundle audits for 202 native code items,
strict ad-hoc app sealing, negative link/data mutation checks, repeat
finalization, real private SVN workflows, eight native cases across two Git
engines, both-architecture merge-library loading, and bundled SSH cleanup.
No GUI app was launched; test receivers and child processes were reaped.
Hosted CI and certificate/sandbox/Finder acceptance remain separate gates.

## Incremental unsigned Debug embedding

The app build uses one coordinated runtime phase. Unsigned Debug builds can
reuse a previously fully embedded and validated payload. Its private Derived
Sources receipt hashes all prepared runtime bytes, helper build products,
configuration, relevant builder/validator/embedding scripts and prompt sources.
It also hashes the complete installed runtime code/data, layout manifest,
permissions, names and helper aliases. Input roots that are symlinks include the
resolved source contents. Modification times alone are never acceptance evidence.
Inputs are checked again after output verification to reject concurrent changes.

Any changed/missing input or output, malformed receipt, permission change or
alias change runs the complete existing embedding/validation/signing/finalizer
sequence. A failed sequence removes its earlier receipt. All runtime trees are
refreshed together, retaining the existing prohibition on partial finalization.
The Finder cache service remains a separately embedded signed build product.

Reuse is limited to `CONFIGURATION=Debug` with `CODE_SIGNING_ALLOWED=NO`.
Release, AppStore and every signed build always run the full pipeline, even if
an identical Debug receipt exists. Full bundle/release audits and CI behavior
checks retain their existing requirements. This development optimization does
not establish certificate, sandbox or App Store acceptance.

Six integrity tests passed. Final local measurements were 54.4 seconds for full
runtime preparation and 5.7 seconds for an unchanged Debug build. Changing an
installed license file forced full preparation and restored its original bytes.
Unsigned AppStore compilation and its complete bundle audit passed with 203
native runtime items and 296 original icons. These measurements cover packaging
overhead, not Swift compilation time. See
[dated cache QA](qa/runtime-embedding-cache-2026-10-13.json).
