# Image conflict selection

Reference: pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseIDiff/MainWindow.cpp` selection mode and `SELECTBUTTON_ID`,
`PicWindow.cpp` Select button, and `TortoiseIDiff.rc`.

The source opens Mine, Base and Theirs in that order, each with its own image
and a Select button at the bottom right. Its selection-mode toolbar omits
Overlay, Blend, Link positions and linked width/height controls. It retains
Fit, Original size, Zoom, Image info and vertical arrangement. The native
replacement follows that layout with three independently fitted image panes,
two draggable splitters and original icon resources. It can arrange panes
side by side or top to bottom. The merged filename extension determines routing, matching StartExtMerge;
content decoding does not select the conflict editor. Rebase Mine/Theirs use the same stage inversion as the
existing text conflict editor; their titles identify the rebase meaning.

Select copies the chosen stage's exact bytes into the working file. The index
stays unmerged until the user answers Yes to “Mark as resolved?”. Answering No
keeps the selected working image and the window open, allowing another choice.
Answering Yes stages that working file and closes after success. Selection does
not commit or continue merge/rebase. Missing Base in add/add conflicts has an empty pane and a Select action that
copies an empty file, matching the source temporary BASE file. An undecodable
side retains its original bytes and Select action; nonregular conflicts continue
through their existing workflows.

The source copies before asking. The native port additionally captures working
bytes/permissions and index stages; it revalidates them before copying and again
before staging after the confirmation. External edits, changed stages and
symlink destinations require reloading. Atomic writes preserve existing file
permissions. Errors after saving leave the window open. Owned operation tokens
prevent queued selection after retirement. Close/Quit is fenced during selection
and while a confirmation is pending; application-wide event monitors are not used.

## Verification and remaining work

The focused Core/text/image/icon/file-comparison suite passed 39 tests,
including all three byte selections, explicit resolution, unchanged unrelated
index/working files, rebase stage inversion, changed bytes/permissions, stale
stages, symlink refusal, missing Base, cancelled writes and mixed-format routing.
The final native receiver passed with system and bundled Git: actual
Mine/Base/Theirs pixels/order, independent fit/zoom, vertical layout, AppKit
Select buttons and production Yes/No sheets; No preserves unmerged index bytes,
Yes rejects an edit during confirmation, Reload recovers and a fresh Yes stages
the selected bytes and closes. HEAD remains unchanged. Close/Quit fencing passed.
Light/dark offscreen captures were visually inspected with readable toolbar,
metadata and Select controls. The receiver keeps sheet parents transparent and
offscreen and then orders them out; all owned windows and fixtures are removed.
Unsigned Debug and App Store builds and bundle audits passed, including
the Finder extension and all 112 original icon resources. See the [QA record](qa/image-conflict-2026-10-10.json). This is a partial native replacement. Broader multiframe/provider
behavior, full format/DPI/border behavior, retained
splitter preferences, physical keyboard/mouse/VoiceOver acceptance and signed
sandbox/Finder/App Store acceptance remain open. The complete TortoiseGit port
is not finished.


Multi-image conflict panes now share native frame/page controls and independent
playback with the comparison viewer. Select still copies the complete original
stage bytes, regardless of the currently previewed frame. See
[frame/page parity](IMAGE-FRAMES-PARITY.md).

All three conflict panes share a transparency color chooser and local Dark Mode,
including the D key. Their navigation/zoom models remain independent. See
[color parity](IMAGE-COLORS-PARITY.md).

## Shared conflict identity family — October 15, 2026

The [shared conflict identity reader](CONFLICT-IDENTITIES.md) supplies captured
operation/branch captions and the default-on guessing policy. Text/image panes,
delete/modify and submodule sides and external merge-tool arguments share the
same stage mapping. The Advanced disable-guessing setting now has a runtime
consumer. Existing source-control mappings and complete-dialog acceptance remain
partial; earlier generic-label gaps are superseded within this documented scope.

[Grouped validation and visual review](qa/conflict-identities-2026-10-15.json)
record actual coverage and remaining limits; no dialog is newly certified.

## Native command surface — October 15, 2026

The connected [native image command family](IMAGE-COMMAND-PARITY.md) replaces
controller-hosted content tool rows with source-ordered AppKit toolbars and
native menu/overflow actions, common keyboard gates, full header tooltips and
stable model ownership across image replacement. See its dated evidence for
validation and remaining acceptance limits.

## Connected conflict dispatch and selection — October 16, 2026

Compared `AppUtils::StartExtMerge/ConflictEdit` and IDiff's `SELECTBUTTON_ID`,
`SetSelectionMode` and `PositionChildren` at the pinned commit. The source chooses
IDiff from the merged filename extension after external-tool inversion. It does
not require every stage to decode. Its Select button copies the original side
file, including an empty temporary Base when stage one is absent.

Core now preserves all captured regular stage bytes for source image extensions.
Unregistered extensions do not enter IDiff merely because the bytes decode as
images. Undecodable sides display a diagnostic and selectable byte size; Select
copies those exact bytes. An absent Base exposes empty-file selection. Decode
success controls image display and frame playback, independently of content
selection. Rebase orientation is checked again before copying or marking resolved;
a changed merge/rebase context requires reload even if the index stages match.

The initiating workspace captures its Merge Tool preferences before asynchronous
entry preparation and supplies those preferences to the actual tool launcher.
Shift, literal path, owner, repository and stage checks retain their existing
captured handoff. The source image fallback remains distinct from two-file Shift
behavior: bypassing an external merge tool on an image still selects IDiff.

The image model owns the actual reload/select/question lifetime through a shared
operation counter, including forced close and cancellation before a Task starts.
Quit remains blocked until the worker or callback settles. An owned resolution
sheet uses the existing one-response session; retirement dismisses it and settles
No. A noncooperative late Yes cannot stage, publish an error or reopen a retired
window. Normal No keeps the selected bytes and unmerged stages; explicit Yes
revalidates and stages without committing or continuing a pending operation.

Earlier dated checks above establish their earlier scope. The new family checks
and remaining physical/signed acceptance are recorded separately in the batch
record; no complete dialog or source-format certification is inferred.

The reviewed light/dark compositor captures show a private real Git conflict with
an undecodable incoming image and its enabled Select action. The first captures
exposed an overlap between the decode message and file-size information; the
native layout now centers the diagnostic and reserves the lower metadata area.
The unchanged originals are published in the [dialog guide](DIALOG-GUIDE.md#image-conflict-selection).

Twenty-four focused Core cases and all four native family cases with both Git
engines pass. The screenshot repair repeated only the affected native case;
Core was not rerun. [The dated record](qa/image-conflict-family-2026-10-16.json)
retains all fixture failures, the native layout repair and exact cleanup scope.
This supersedes earlier content-only routing and disabled missing-Base behavior;
complete physical, format and signed acceptance remain open.


## Pane controls and native acknowledgement lifetime (2026-10-31)

Frame controls now receive equality-fenced parent admission changes during
reload, selection, a peer preview read and native sheets. These boundaries stop
playback; returning to an editable window restores controls without starting
players or resetting the retained frame. The same ownership rule applies to the
standalone three-input image selection window. Its accepted preview drop can
publish its own result while preventing competing pane commands.

Select retains its worker, repository permission and Quit blocker through actual
sheet detachment, rather than treating a response callback as physical closure.
Forced retirement cancels the question and drains the accepted operation without
reviving the window. Original full-file selection and No's unmerged-index
semantics remain unchanged. See the connected fixture and focused validation
scope in [frame/playback parity](IMAGE-FRAMES-PARITY.md#three-pane-command-admission-and-sheet-completion-2026-10-31).
This source change is not yet a signed or physical acceptance result.
