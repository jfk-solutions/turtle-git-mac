# Request Pull dialog parity

[Upstream manual](https://tortoisegit.org/docs/tortoisegit/tgit-dug-patch.html#tgit-dug-request-pull).

Reference: pinned RequestPullDlg.cpp/.h, RequestPullCommand.cpp/.h,
AppUtils.cpp RequestPull and IDD_REQUESTPULL. The pinned libgit2 branch-name
helper is also recorded in QA because it controls the End input gate.

The native Request pull window retains Start, Repository URL, End, Send Mail
after create, OK/Cancel/Help, and horizontal resizing. Start offers local/remote
branches and a native Log picker with working-tree rows hidden. A picked hash
replaces Start; Cancel retains it. The app Repository menu and shared action
routing open the dialog. Upstream has no Request Pull shell-menu row in the pinned
MenuInfo; no Finder condition is added. App menu artwork reuses the original
unified-diff icon rather than claiming a distinct source Request Pull icon.

Last Start, URL and End are stored per repository. URL history is global and
case-sensitive, using the shared HistoryCombo save/load/deletion behavior. Send
Mail is global and initially false. Explicit End/URL presets override saved
values only when nonempty. Like source, URL history and last fields save before
End validation; Send Mail saves only after it passes. The End default is HEAD,
but the pinned source branch-name helper rejects HEAD as a branch name: choose
a valid branch/tag to submit. Leading dashes, invalid ref names and the source's
Windows quote/pipe/angle-bracket exclusions also reject. Start's remotes/ prefix
is removed only for execution, after storing the supplied text.

Git runs `request-pull -- <start> <url> <end>` with argument arrays, retains raw
stdout bytes as pullrequest.txt in a private temporary directory, and checks the
advertised URL rather than publishing refs. A transport/generation failure retains
inputs and reports the source Failed to create pull-request message. The result
uses Settings → Alternative Editor (TextEdit or the configured application or
executable), or the shared native Send Mail options when Send Mail is selected.
Configured/direct SMTP and mail-client drafts retain their separate delivery
paths after those options. The Git operation sends no message. Mail recipients
and sending are controlled in the selected native options or mail composer. If editor/mail handoff fails, Open request
retains access to the generated document. Successful documents remain available
for the external editor/composer, as upstream keeps its temporary document.

Native cancellation stops the owned Git process and suppresses document handoff;
a retry uses a fresh token. This adapts the source system progress dialog, which
checks its cancelled state after RunLogFile completes. Native fields stay locked
until cleanup, and a duplicate submission is rejected. Composer activity also
locks submission/close. The controller retains repository access and its owned
Log picker, and closes the picker when the parent closes.

[QA](qa/request-pull-2026-10-08.json) records real published request text, UTF-8
content, tag/bare operation, argument/End validation, failure and pre-cancellation,
mixed staged/unstaged preservation, and native histories/presets/Log callbacks,
captured options and owned cancellation/retry. That historical checkpoint used receiver callbacks for native handoffs; the
October 19 continuation below separately covers configured editor and actual
mail-options routing.

## Remaining parity

Physical fields/popup/Shift+Delete/Log sheet/Cancel/Escape/resize/default/button
behavior and complete appearance/accessibility remain unverified. Controlled
private editor execution and native mail options are scoped checks; real
receiving applications, SMTP/TLS/Apple Mail, credentials and signed sandbox
permissions require their corresponding installed workflows. Branch-name
validation uses Git CLI plus source exclusions rather than libgit2; complete
Unicode/pathological validation equivalence remains unverified. Long-lived
external editor retention and physical Push follow-up acceptance remain open.
Screenshots predate this continuation. This is a partial native replacement,
not full dialog/application or distribution parity.

Push success now routes the captured destination into this dialog; see [Push parity](PUSH-PARITY.md).

## Native SMTP document handoff

Configured and direct SMTP now open the shared Send Mail options/progress
workflow from Request Pull. Like AppUtils.cpp, this uses the generic
CSendMailCombineable document mode and `m_bCustomSubject`, rather than parsing the
request as a format-patch file. Subject remains editable with Combine One Mail
off and does not change when highlighting rows. Ordinary single messages retain
all document lines; combined inline messages add each full filename and its text.
The text path adapts source line-reading to UTF-8 and CRLF; attachments preserve
original bytes, including non-text content. Original selected order and duplicate
rows are retained across preparation.

The Request Pull owner retains repository access and the options/progress
workflow, blocks resubmission/close during mail, and releases its mail state after
options Cancel or result close. As upstream, successful request generation is
independent of the eventual SMTP result. Failed delivery remains visible in the
shared progress window. Generated documents remain in the application's private
temporary storage for fallback/external use. The Send model accepts only the
explicitly supplied generated file within that private root without an external
security-scope grant; external dropped files still require their normal grants.

Core tests cover all four generic document modes, full text before/after blank
lines, custom subjects, duplicate order, line endings, empty text, exact binary
attachment capture, UTF-8 rejection and header/directory guards. Hidden native
verification and bundle checks are recorded in
[Request Pull mail QA](qa/request-pull-mail-2026-10-10.json). Full mail-client
options/lifecycle, legacy document encodings, physical UI/SMTP invocation and
signed sandbox/App Store acceptance remain pending.

Mail-client mode now also uses native custom-subject options and the Apple Mail
visible-draft adapter rather than the file-only sharing service. See
[client parity/evidence](SEND-PATCH-PARITY.md#delivery-modes).
The earlier system-composer bypass describes a historical checkpoint. Actual
Apple Mail execution and full modal mail-client lifecycle remain unverified.


## Connected Request Pull invocation and ownership family — October 15, 2026

Start's ellipsis now opens single-selection Log at the entered revision before
its first history load. It shares the owning preferences, appearance, visibility,
repository lease and production downstream commands. Working-tree rows stay
hidden. One captured request owns the options until the sheet retires. Changing
Start, URL, End or Send Mail while it is open rejects that result; duplicate,
Cancel, refused-presentation and retired callbacks cannot replace inputs.
Creation, reload, URL deletion, fallback Open and owner closure remain gated while
that picker is owned. Accepted/Cancel results restore the owner after sheet exit.

Initial branch reads, End's `check-ref-format` validation and generation now use
cancellable owned Git processing. Validation preserves an execution failure or
cancellation instead of converting either into an invalid branch name. Requested
Close cancels and waits; forced Close fences publication while global Quit
accounting and repository permissions survive until child cleanup. Cancel during
generation retains the existing retry/error flow; Close suppresses a redundant
cancel alert while retiring the owner. Initial loading has its own status text.
App Store repository access is checked before reads and generation. Hidden denied-
scope fixtures exercise that gate but do not establish signed sandbox acceptance.

Generated request bytes retain the existing private document and Open request
fallback. Failed external-open dispatch keeps the options and document; successful
fallback retires the options and leaves the document for the editor. Mail options
and progress inherit the owner appearance/visibility and are invalidated on forced
owner closure, suppressing late submissions/completion. Existing mail options
still require explicit user review; no link or picker result sends anything.

### macOS command-link presets

The existing `turtlegit://action` protocol now adapts RequestPullCommand's `endrev`
and `url` options. A request with `command=requestPull` and an absolute repository
`path` can include one `endrev` and one `url` query value. Build the query with URL
encoding so punctuation, spaces and Unicode stay literal. These fields are valid
only for Request Pull; duplicates, missing values and NUL are refused. Empty
values keep the source's saved-default fallback. The advertised URL supplies the
editable Repository URL field, not a filesystem permission. The normal repository
authorization/adoption pipeline runs before presentation, and generation waits
for OK. Windows `/command:` executable syntax is not added by this URL adaptation.

The actual dispatcher was exercised with private snapshot/preferences and its
existing repository authorization path. It delivered the requested End/URL into
the native dialog without generating a document. The Core URL cases cover legacy
links, literal round trips, empty fields and malformed/wrong-command fields.

The Debug build passed. The affected Core group ran 19 cases: 18 passed and one
new fixture incorrectly compared directory URL slash hints. Its corrected path
comparison passed in the focused recheck, giving cumulative passing evidence for
all 19 cases. The new native fixture initially attempted fallback while its error
alert remained open; it now dismisses that actual alert before using Open request.
The grouped native result and remaining acceptance limits are recorded in
[Request Pull lifecycle QA](qa/request-pull-lifecycle-2026-10-15.json). The runner
reuses the patch-family Debug object/module cache instead of recompiling the app.
No full Core suite or new Store build is claimed. Physical keyboard/menu/alert
interaction, live editor/SMTP/Apple Mail, full source visual/VoiceOver parity,
signed Finder/repository grants and App Store acceptance remain open.


Both the existing generation/mail and new lifecycle checks passed with system
and bundled Git: four accepted fixture/engine pairs. The failed fixture receiver
and all four accepted receivers were reaped and independently checked absent.
No external editor or mail application was launched and no message was sent.

## Primary command presets and draft ownership — October 18, 2026

`requestpull` now accepts the pinned `RequestPullCommand.cpp` editable `endrev`
and `url` values. Empty/missing values retain source history/default behavior.
One selected repository/path-file source is resolved through the normal authorized
repository route; no request generation or mail delivery occurs on launch.
A deterministic command-owned window preserves its current draft, Start picker,
active generation or mail handoff against a competing invocation. Ordinary app
entry can still own independent requests. The default controller now inherits
workspace presentation preferences instead of implicitly using the standard domain.

The existing Start Log, URL history, end validation, generated document and
Send Mail workflow remain its native consumers. Mail preparation and direct
`sendmail` entry now share captured file/permission/sender ownership; see
[mail entry evidence](qa/mail-commands-2026-10-18.json). Local private repositories
and injected delivery do not certify public remotes, mail applications, physical
input/visual parity or current signed Store/Finder acceptance.


## Source waiting window and configured editor family — October 19, 2026

Source `RequestPullDlg.cpp:76–80` obtains all branches through GetBranchList;
`Git.cpp:185–215` applies the configured local-first comparator. Native Start
now uses the originating preferences and keeps that source order, including
qualified remote names, instead of applying a second alphabetical sort.

Source `AppUtils.cpp:2947–2981` owns a separate System Progress window while
creating the request. Its two lines describe generation and waiting; it hides
the percentage bar and stops before errors, cancellation or editor/mail output.
The native replacement uses an owned indeterminate waiting sheet and direct
Cancel, starting after accepted End validation. Source ShowModeless uses its
second boolean for immediate display; it does not request PROGDLG_MODAL. Blocking
the retained options parent is the macOS sheet adaptation. During generation,
Cancel/Escape belongs to that active waiting window; after its cancellation
acknowledgement, the options can be closed or retried. AppKit sheet titlebar
closure is not used as a cancellation action. Actual Git generation and
private result writing retain their worker/access lifetime. Result, error and
cancellation continuations wait for the native progress sheet to detach.

Both initial document opening and Open request use the shared awaitable
Alternative Editor path, matching `AppUtils.cpp:3011` and
`LaunchAlternativeEditor:684–694`. Accepted editor settings, document bytes,
permissions and presentation survive later draft/preference changes. Launch
failure retains the generated document for retry. A successful executable
launch remains detached under the existing tool-process owner; TurtleGit does
not terminate a user's editor when its options close.

Request Pull also enters the existing Git/SSH askpass routing. Git's
`git-request-pull.sh` invokes `ls-remote` on the advertised repository, so it
needs the same authentication inheritance as other remote operations. Explicit
askpass/configuration/headless overrides retain their existing precedence.
This change authorizes the actual command identity, not matching text inside
an unrelated local command.

One-shot native failure/cancel acknowledgements, submission contexts, Quit
epochs and forced retirement prevent late editor/mail launches or stale field
edits. The Start Log controller remains owned through actual picker reads and
native sheet retirement. Root entry preserves a live edited draft and refuses
a cached retiring controller. [Batch evidence](qa/request-pull-workflow-2026-10-19.json)
records actual checks and limitations; this does not certify public transports,
physical windows or App Store distribution.

The selected Core group passed 12 methods. Debug builds passed before and after
the native Cancel-control repair. Six distinct native case/engine pairs passed
cumulatively with system and bundled Git. Early retained fixtures assumed
immediate picker drain and ordinary titlebar closure on modal sheets; recorded
failures led to actual-drain waits and checks that press the native Cancel
button. Original lifecycle and helper-cleanup assertions remain. All twelve
receivers, including failed attempts, were reaped and their PIDs/process groups
independently checked absent. These checks used private state and invisible
windows; they do not certify physical interaction or current signed delivery.
