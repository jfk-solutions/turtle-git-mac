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

Repeated builds replace helper aliases with fresh runtime trees before
finalization. Re-running finalization on an unchanged complete bundle audits it
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
