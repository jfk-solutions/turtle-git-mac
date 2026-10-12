# CI runtime reuse

The macOS workflow now restores exact prepared runtime packages for Git/LFS/SVN,
OpenSSH, EditorConfig, IssueRegex and MergeDiff. Existing graph and ARM SVN
component caching remains in place. This removes unchanged dependency compilation
from subsequent port batches; it does not skip the full Core suite, native
receivers, embedding/signing checks, real SVN workflows or deployment audits.

`Configuration/CIRuntimeCaches.json` declares each package, its complete builder/
reconstruction inputs and its validator. `scripts/ci-runtime-cache-key.py` hashes
those bytes, the selected recipe, its own implementation, runner architecture and
the recorded compiler/Xcode/SDK/CMake fingerprint. Missing inputs fail rather than
producing an empty dependency hash. Ordinary native Swift edits do not invalidate
unchanged helper builds.

Git's key also hashes the transferred ARM-job SVN component manifest, whose
inventory covers the built component files. MergeDiff's key hashes the installed
SVN manifest and the actual APR/Subversion headers its builder consumes. Changed
transitive binaries/toolchains therefore cannot reuse an unrelated package merely
because the top-level C adapter stayed unchanged.

Each workflow group uses exact restore → build on miss → unconditional validate
→ save on miss. There are no prefix/partial restore keys. Prepared packages include
their source archives, licenses and reconstruction scripts; cache paths do not
include installed apps, signing credentials, test repositories or user preferences.
The cache holds raw helpers; downstream app embedding and signing still run.

Explicit save runs before the long application checks, so a successfully built and
validated runtime can be reused even if a later app test fails. This follows
GitHub's [separate restore/save actions](https://github.com/actions/cache/blob/main/restore/README.md).
A cache miss builds normally. A restored package that fails validation is not used.
Keys are content-addressed; cache availability/eviction is an optimization, not
proof of application correctness.

## Evidence

Five focused contract tests passed: stable keys; toolchain/runner changes; every
declared input's dependent-key invalidation; missing transitive manifest/header
refusal; unchanged helpers across native app edits; and workflow ordering, exact
paths and unconditional validation. Both workflow jobs also parsed as YAML.

All five actual local prepared runtime validators passed as one grouped audit,
including architecture/deployment/linkage and source/license provenance. Git/LFS
local workflows, OpenSSH private-agent loading/removal, EditorConfig inherited
rules and IssueRegex offsets/extraction also ran. MergeDiff's validator audits
its adapter; the Git/SVN audit covers the shared dynamic libraries.
No app window was launched and no runtime was rebuilt during this audit.
See [the validation record](qa/ci-runtime-caches-2026-10-12.json).

Actual hosted restore/save hits, total CI timing improvements and full hosted
workflow success remain unverified until new runs exercise this workflow. Signed
Finder/App Store and complete application parity remain separate open gates.
