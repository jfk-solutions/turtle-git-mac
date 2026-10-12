# Git daemon — native implementation and remaining acceptance

Pinned source: `Commands/DaemonCommand.cpp`, `MenuInfo.cpp`,
`IDS_DAEMON_SECURITY_WARN` and the generic `ProgressDlg` at
`7338078f8ddd924b8cddee35f512f2286072136d`.

The app and Finder route Daemon to one native window per repository root,
including bare repositories. Finder retains the source icon, selection clauses,
placement between Browse References and Revision Graph, and shared menu
preferences for visibility, first-level placement and icons. No Git command is
run inside the Finder extension to construct this menu.

The initial native warning retains the source text, Proceed/Abort and the
remembered-warning choice. Only Proceed saves that choice; Abort clears it.
After Proceed, the window displays repository URLs, the command, bounded Git
output, lifecycle status and Cancel, changing to Close after exit. Native system
colors support light and dark appearances. This adapts the source's warning plus
generic progress window rather than inventing a dedicated upstream dialog.

Serving defaults retain `git daemon --verbose --export-all --base-path=<root>`:
port 9418 and Git's default listen interfaces. The source exposes repository
data without authentication or encryption. The port does not enable
`receive-pack`. IPv4 and bracketed IPv6 URLs come from local interface addresses;
zone IDs are omitted, with localhost as fallback. Numeric custom listen addresses
and ports are supported by the Core runner for private validation, without
changing the normal user-facing defaults.

The server runs outside the repository actor so a long-running listener does not
block other dialogs. Its real repository security scope remains retained through
exit. An owned process group handles cancellation, including workers; natural
leader exit also kills remaining workers before reaping the leader and releasing
its reserved process-group ID. Output is drained continuously, with a bounded
diagnostic tail and bounded producer mailbox instead of an unlimited spool or
one UI task per chunk. Readiness is detected across chunk boundaries even when
the visible-output queue fills.

Cancel stops the server and leaves the final output visible. Closing during a
run requests cancellation and closes only after the owned process exits. Forced
owner closure also cancels it, and a process-count guard prevents Quit while
cleanup is pending. The App Store configuration adds the incoming-network
entitlement; an unsigned build is not evidence of signed sandbox acceptance.

Remaining acceptance: physical source comparison in both appearances, signed
Finder handoff and bookmark access, firewall prompts, actual LAN/IPv6 serving,
bundled-helper sandbox inheritance and App Store review. Private tests bind only
loopback and do not establish those gates. The complete app remains an unfinished
port; adding this command does not certify the full dialog inventory.

Grouped validation on 2026-10-12: Debug arm64 build exited 0 (with existing
compiler warnings and exit-zero diagnostic noise). Forty focused Core tests
passed, zero failures, in 4.901 seconds. Real loopback Git clone, immediate port
reuse, occupied-port errors, pre-cancellation, unchanged HEAD/index, and worker
cleanup on natural exit and cancellation passed. The actual Finder menu builder
verified all 56 implemented root entries against the pinned order fixture; the
Core condition oracle now covers 59 commands including the three LFS children.
One combined native receiver compilation/process verified warning, remembered
Proceed, Abort, split readiness, output flooding, Cancel/close, forced closure
and Quit ownership alongside the existing LFS/mail fixtures. Daemon native
process responses were injected; real mail used only the owned loopback SMTP
fixture. No installed app or Finder extension was activated. See
[the dated record](qa/daemon-batch-2026-10-12.json).
