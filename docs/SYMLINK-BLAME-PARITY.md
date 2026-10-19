# Symbolic-link Blame workflow

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This is a connected file-mode and document workflow continuation, not complete
Blame or whole-app certification.

## Source and behavior

Related native entry resources are `src/Resources/TortoiseProcENG.rc` /
`IDD_LOGMESSAGE` and `IDD_REPOSITORY_BROWSER`; their existing Blame icons and
menu order remain. This continuation changes their dispatched file-mode behavior,
not their static-control mappings.

`TortoiseGitBlameDoc.cpp` defaults revision to HEAD (around line 86) and runs
`git blame -p <revision> -- <path>` (around line 216). Pinned Git's
`blame.c::find_origin` accepts any commit-tree `OBJ_BLOB`, including mode `120000`.
The separate uncommitted readlink branch is not the source's default HEAD path.

Core now admits mode `120000` alongside ordinary/executable file blobs in its
pinned contents reader, Blame gate and previous-parent comparison gate. The
original object bytes, encoding, attribution parser, exact path arguments,
history/rename behavior and cancellation remain shared. The link-target text
is displayed; its target file/directory is never opened. Directory trees and
mode `160000` gitlinks remain unsupported documents.

The native File Open and four-file MRU validate the canonical repository and
parent directories while retaining the leaf path. Leaf classification permits
regular files and symbolic links, including dangling links. The file chooser
does not resolve aliases. Reusing the current repository grant checks the parent,
then preparation validates the requested Git path and all owned reads before
replacing the current document. A failed/cancelled preparation retains it.

Log's working-file Blame uses the pinned HEAD blob and its real cancellation/Quit
ownership instead of a working-file open that can dereference the link. Historical
Log and Repository Browser keep their captured path/revision handoff. Existing
source-line, parent/history and reblame actions use the same Core reader.

Finder shell eligibility classifies the selected leaf rather than a directory
target. Finder/command-line repository adoption and permission targets use the
link's parent for Blame, retaining the original request path for dispatch. Missing
historical parents walk to an existing contained ancestor before metadata
preparation. This does not authorize access through an escaping parent symlink
or inside Git administrative paths.

## Validation and remaining scope

[Batch QA](qa/symlink-blame-2026-10-19.json) records actual implementation hashes,
attempts, failures/repairs and retained passes after the grouped checkpoint.
The new private Core cases cover target-text attribution, working-link changes,
rename/type transitions, previous/history navigation, checkout surrogates, exact
Unicode paths, Finder eligibility and refusal/cancellation boundaries. Native
checks exercise real document/menu/router models with private grants and owned
processes. A fixture's existence does not establish a pass.

Physical Finder/powerbox/menu gestures, native alias-selection delivery, MRU
relocation with real sandbox grants, VoiceOver and current signed/App Store
acceptance remain open. Binary/malformed link text and unsupported encodings
retain the ordinary Blame diagnostic policy. Broader Blame, path namespace and
all revision/menu variants remain separate acceptance requirements.

The grouped checkpoint passed 54 distinct Core methods (53 retained and the one
legacy contract correction rechecked), the Debug app build and one native receiver
using packaged Git. The receiver's real document/router/history actions and held
reader cancellation passed; it was reaped. Initial fixture compile errors and the
old symlink-rejection assertion are retained in the QA record. No production
behavior repair or app rebuild followed these fixture/contract corrections, and
no full Core suite or additional native family was repeated. Existing screenshots
remain earlier UI evidence; this batch produced no new physical captures.
