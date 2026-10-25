# Settings context and page handoffs

Partial continuation of [Settings completion](SETTINGS-COMPLETION-PARITY.md),
against pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
The Settings family includes `src/Resources/TortoiseProcENG.rc / IDD_SETTINGSMAIN`
and the Remote page `IDD_SETTINREMOTE`.

## Source and native ownership

`Settings/Settings.cpp` constructs repository-dependent pages and selects the
requested initial page. The native app uses one application-owned property sheet
with cached pages, rather than one separate Windows process per invocation.
Its asynchronous Cancel/OK completion must therefore preserve a later request
until the old owner actually closes.

Previously `SettingsPresentationService.show` called `performClose` for a scope
change and immediately reused its still-present controller. Owned close now
drains asynchronously: the old window later disappeared, losing the requested
Global/repository context. Command-selected pages and Remote's no-fetch intent
could also be lost during terminal completion.

## Connected handoff behavior

An accepted scope change queues the destination context, page and no-fetch
intent until the exact old window completes its owned close. Repeated requests
replace the pending destination. Same-context activation retains the existing
page cache. Dirty drafts, active operations and refusing close delegates retain
the current visit; a refused switch is not silently replayed later.

Only a normal owned completion can replay the request. Forced retirement,
repository replacement, replacement workspace installation and clean Quit cannot
reopen it against another owner. Old window notifications and old workspace
callbacks cannot clear, block or open a replacement workspace's Settings. A
read-only workspace retirement witness covers the clean termination path that
does not first set confirmingQuit.

The existing Remote native list, footer and draft/Git semantics remain in their
own reviewed family. This continuation fixes presentation handoffs rather than
claiming those previously repaired controls were still missing.

## Verification and remaining acceptance

The [grouped checkpoint](qa/commit-settings-source-parity-2026-10-25.json) records
eight Settings case/engine pairs passing with system and bundled Git. Actual
coordinator callbacks, footer Cancel/OK, Remote URL persistence and owned close
cover context/page/no-fetch requests, refusal, terminal races, owner replacement
and clean retirement with private inputs and offscreen windows. All receivers
were reaped. These passes were retained after the separate Commit-only routing
repair; unchanged Settings code was not tested again.
Physical gestures, VoiceOver, signed sandbox grants and complete Settings
behavior/layout parity require separate acceptance.
