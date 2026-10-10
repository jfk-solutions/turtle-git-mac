import AppKit
import TurtleGitCore

@main struct MergeAbortVerification {
    @MainActor static func waitUntil(_ predicate: @escaping () -> Bool, line: UInt = #line, diagnostic: () -> String = { "" }) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        if !predicate() { FileHandle.standardError.write(Data(("Abort wait diagnostic: " + diagnostic() + "\n").utf8)) }
        precondition(predicate(), "Native Abort timed out at receiver line \(line)")
    }
    @MainActor static func key(_ window: NSWindow, _ code: UInt16, _ text: String) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        precondition(window.performKeyEquivalent(with: event), "Abort key was not handled")
    }
    @MainActor static func capture(_ window: NSWindow, name: String) async throws {
        guard CommandLine.arguments.count > 3 else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[3])
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(nanoseconds: 150_000_000)
            let content = window.contentView!
            content.layoutSubtreeIfNeeded()
            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            window.effectiveAppearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: bitmap) }
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + "-" + suffix + ".png"))
        }
        window.appearance = NSAppearance(named: .aqua)
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Abort QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["switch", "-c", "feature"])
        try Data("theirs\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "theirs")
        _ = try await repo.run(["switch", "main"])
        try Data("ours\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "ours")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        var options = MergeOptions(); options.revision = "refs/heads/feature"
        let suite = "TurtleGit.Abort.QA." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let idle = MergeAbortWindowModel(repository: repo, access: nil, preferences: preferences)
        var comparisons = 0, idleClosed = 0
        idle.onShowModified = { comparisons += 1 }; idle.close = { idleClosed += 1 }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        precondition(idle.mode == .merge && !idle.busy && !idle.showingProgress)
        idle.showModified(); idle.close(); idle.invalidate(); idle.showModified(); idle.abort()
        precondition(comparisons == 1 && idleClosed == 1 && !idle.showingProgress)
        let idleIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")); precondition(idleIndex == index)
        DialogGeometry.install(preferences: preferences)
        let owner = MergeAbortWindowController(repository: repo, access: nil, preferences: preferences)
        let parent = owner.window!; parent.alphaValue = 0; parent.orderFront(nil)
        var ownerClosed = 0; owner.onClosed = { ownerClosed += 1 }
        precondition(parent.contentView!.bounds.width >= 660 && parent.contentView!.bounds.height >= 265, "Options controls must retain usable width/height")
        try await capture(parent, name: "merge-abort-options")
        owner.model.showModified()
        let comparison = owner.modifiedFiles!, sheet = comparison.window!; sheet.alphaValue = 0
        precondition(parent.attachedSheet === sheet && sheet.sheetParent === parent && owner.model.hasChild)
        try await waitUntil { !comparison.model.busy }
        precondition(comparison.model.from == "HEAD" && comparison.model.to == ComparisonRevision.workingTree.label)
        key(parent, 36, "\r"); key(parent, 53, "\u{1b}")
        owner.model.abort(); owner.model.close(); owner.model.showModified()
        precondition(!owner.model.showingProgress && owner.modifiedFiles === comparison && ownerClosed == 0)
        precondition(!owner.windowShouldClose(parent))
        let delegate = TurtleGitApplicationDelegate()
        precondition(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        sheet.close()
        try await waitUntil { parent.attachedSheet == nil && !owner.model.hasChild }
        owner.model.showModified()
        let forcedChild = owner.modifiedFiles!, forcedSheet = forcedChild.window!
        forcedSheet.alphaValue = 0
        parent.close()
        try await waitUntil { forcedSheet.sheetParent == nil && owner.modifiedFiles == nil }
        precondition(ownerClosed == 1 && !forcedSheet.isVisible)
        owner.model.abort(); precondition(!owner.model.showingProgress)

        // Force-close while HEAD preflight is running: retain busy until reaped,
        // and never publish the cancelled result to the repository factory.
        let helper = root.appendingPathComponent("abort-slow-git"), ready = root.appendingPathComponent("abort-ready")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        #!/bin/sh
        for arg in "$@"; do
          if [ "$arg" = 'HEAD^{commit}' ]; then
            /bin/sleep 30 &
            child=$!
            /usr/bin/printf '%s\\n%s\\n' "$$" "$child" > \(quote(ready.path))
            wait "$child"
          fi
        done
        exec \(quote(git.path)) "$@"
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let slow = GitRepository(root: root, executable: helper)
        let running = MergeAbortWindowController(repository: slow, access: nil, preferences: preferences)
        let runningWindow = running.window!; runningWindow.alphaValue = 0; runningWindow.orderFront(nil)
        var published = 0; running.model.onChanged = { _ in published += 1 }
        running.model.abort()
        try await waitUntil { ((try? String(contentsOf: ready)) ?? "").split(separator: "\n").count == 2 }
        let pids = try String(contentsOf: ready).split(separator: "\n").compactMap { Int32($0) }
        precondition(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        let separateProgress = running.progress!, progressWindow = separateProgress.window!
        precondition(progressWindow !== runningWindow && progressWindow.isVisible && !runningWindow.isVisible)
        runningWindow.close()
        precondition(running.model.busy, "Cancellation is a request, not process completion")
        try await waitUntil { !running.model.busy && pids.allSatisfy { kill($0, 0) == -1 } }
        precondition(published == 0 && running.model.output.isEmpty && running.model.postActions.isEmpty && !running.model.success)
        let afterForcedIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")); precondition(afterForcedIndex == index)
        // Ordinary titlebar cancellation is independent of forced-owner close.
        try FileManager.default.removeItem(at: ready)
        let ordinary = MergeAbortWindowController(repository: slow, access: nil, preferences: preferences)
        ordinary.window!.alphaValue = 0; ordinary.window!.orderFront(nil)
        ordinary.model.abort()
        try await waitUntil { ((try? String(contentsOf: ready)) ?? "").split(separator: "\n").count == 2 }
        let ordinaryPids = try String(contentsOf: ready).split(separator: "\n").compactMap { Int32($0) }
        let ordinaryProgress = ordinary.progress!, ordinaryWindow = ordinaryProgress.window!
        key(ordinaryWindow, 36, "\r"); precondition(ordinary.model.busy && ordinaryWindow.isVisible)
        key(ordinaryWindow, 53, "\u{1b}"); precondition(ordinaryWindow.isVisible && ordinary.model.busy)
        try await waitUntil { !ordinary.model.busy && ordinaryPids.allSatisfy { kill($0, 0) == -1 } }
        precondition(ordinary.model.cancelled && !ordinary.model.success && ordinary.model.postActions == [.retry])
        precondition(ordinary.progress == nil && !ordinaryWindow.isVisible && !ordinary.window!.isVisible)
        print("Abort ownership: hidden HEAD/working sheet, duplicate/OK/Close/Quit gates, child close and forced parent teardown; active HEAD-preflight forced-close cancellation reaps leader/child and rejects result callbacks. Private preferences only.")
        for mode in MergeAbortMode.allCases {
            let controller = MergeAbortWindowController(repository: repo, access: nil, preferences: preferences)
            let optionsWindow = controller.window!; optionsWindow.alphaValue = 0; optionsWindow.orderFront(nil)
            controller.model.mode = mode
            let lock = root.appendingPathComponent(".git/index.lock"); try Data().write(to: lock)
            key(optionsWindow, 36, "\r")
            let firstProgress = controller.progress!, firstWindow = firstProgress.window!
            precondition(firstWindow !== optionsWindow && firstWindow.isVisible && !optionsWindow.isVisible)
            try await waitUntil { !controller.model.busy }
            precondition(!controller.model.success && controller.model.postActions == [.retry])
            precondition(firstWindow.contentView!.bounds.width >= 600 && firstWindow.contentView!.bounds.height >= 300)
            if mode == .merge { try await capture(firstWindow, name: "merge-abort-reset-failed") }
            try FileManager.default.removeItem(at: lock)
            controller.model.perform(.retry)
            if mode == .merge {
                precondition(controller.progress == nil && optionsWindow.isVisible && !firstWindow.isVisible)
                controller.model.abort()
                precondition(controller.progress !== firstProgress && !optionsWindow.isVisible)
            } else { precondition(controller.progress === firstProgress && !optionsWindow.isVisible) }
            try await waitUntil { !controller.model.busy }
            precondition(controller.model.success)
            let finalWindow = controller.progress!.window!
            key(finalWindow, 76, "\r")
            precondition(controller.progress == nil && !optionsWindow.isVisible && !finalWindow.isVisible)
        }
        print("Abort native lifecycle: separate hidden options/reset-progress windows; Merge failure retry reopens options/new progress; Mixed/Hard retry keeps progress; final close retires owner.")
        let streamHelper = root.appendingPathComponent("abort-stream-git")
        let streamReady = root.appendingPathComponent("abort-stream-ready"), release = root.appendingPathComponent("abort-stream-release")
        let behaviorFile = root.appendingPathComponent("abort-stream-behavior")
        let streamScript = """
        #!/bin/sh
        for arg in "$@"; do
          if [ "$arg" = reset ]; then
            /usr/bin/printf 'Resetting α\\n'
            /usr/bin/printf 'tracked paths\\n' >&2
            /usr/bin/printf '%s\\n' "$$" > \(quote(streamReady.path))
            behavior=$(/bin/cat \(quote(behaviorFile.path)))
            if [ "$behavior" = limit ]; then
              for batch in 1 2 3 4 5; do
                /usr/bin/head -c 4000 /dev/zero | /usr/bin/tr '\\000' x
                /usr/bin/printf '\\n'
              done
            fi
            while [ ! -f \(quote(release.path)) ]; do /bin/sleep 0.05; done
            if [ "$behavior" = failure ]; then /usr/bin/printf 'reset refused\\n' >&2; exit 7; fi
          fi
        done
        exec \(quote(git.path)) "$@"
        """
        try Data(streamScript.utf8).write(to: streamHelper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: streamHelper.path)
        preferences.set(16, forKey: "GitOutputLimitinKiB")
        for behavior in ["success", "failure", "cancel", "forced", "limit"] {
            try? FileManager.default.removeItem(at: streamReady); try? FileManager.default.removeItem(at: release)
            try Data(behavior.utf8).write(to: behaviorFile)
            let streamRepo = GitRepository(root: root, executable: streamHelper)
            let controller = MergeAbortWindowController(repository: streamRepo, access: nil, preferences: preferences)
            controller.window!.alphaValue = 0; controller.window!.orderFront(nil)
            var callbacks = 0; controller.model.onChanged = { _ in callbacks += 1 }
            controller.model.abort()
            try await waitUntil { controller.model.output.contains("Resetting α") && controller.model.output.contains("tracked paths") && FileManager.default.fileExists(atPath: streamReady.path) }
            precondition(controller.model.busy && !controller.model.success && controller.model.postActions.isEmpty)
            let pid = Int32(try String(contentsOf: streamReady).trimmingCharacters(in: .whitespacesAndNewlines))!
            if behavior == "limit" {
                try await waitUntil { controller.model.output.contains("Output truncated") }
                precondition(controller.model.busy && controller.model.output.utf8.count < 17000)
            }
            if behavior == "failure" { try await capture(controller.progress!.window!, name: "merge-abort-running") }
            let before = controller.model.output
            if behavior == "forced" { controller.window!.close() }
            else if behavior == "cancel" { controller.model.cancel() }
            else { try Data().write(to: release) }
            try await waitUntil { !controller.model.busy && kill(pid, 0) == -1 }
            if behavior == "forced" {
                precondition(callbacks == 0 && controller.model.output == before && controller.model.postActions.isEmpty)
            } else {
                precondition(callbacks == 1)
                if behavior == "cancel" { precondition(controller.model.cancelled && !controller.model.success && controller.model.output.contains("tracked paths")) }
                else if behavior == "failure" {
                    precondition(!controller.model.success && !controller.model.cancelled && controller.model.output.contains("reset refused") && controller.model.output.contains("Git command failed (7)."))
                    try await capture(controller.progress!.window!, name: "merge-abort-stream-failed")
                } else {
                    precondition(controller.model.success && !controller.model.cancelled)
                    precondition(controller.model.output.components(separatedBy: "Resetting α").count == 2, "Streamed output must not be repeated at completion")
                }
                if behavior == "cancel" { precondition(controller.progress == nil, "Accepted cancellation retires progress after process unwind") }
                else if behavior == "failure" { key(controller.progress!.window!, 53, "\u{1b}") }
                else { controller.model.close() }
            }
            precondition(controller.progress == nil && !controller.window!.isVisible)
        }
        preferences.set(true, forKey: "ConfirmKillProcess")
        for scenario in ["decline", "accept", "finished-no", "finished-yes", "forced", "stale"] {
            try? FileManager.default.removeItem(at: streamReady); try? FileManager.default.removeItem(at: release)
            try Data("success".utf8).write(to: behaviorFile)
            preferences.set(scenario.hasPrefix("finished") ? GitProgressAutoClose.noErrors.rawValue : GitProgressAutoClose.manual.rawValue, forKey: "AutoCloseGitProgress")
            let controller = MergeAbortWindowController(repository: GitRepository(root: root, executable: streamHelper), access: nil, preferences: preferences)
            controller.window!.alphaValue = 0; controller.window!.orderFront(nil)
            var changes = 0; controller.model.onChanged = { _ in changes += 1 }
            controller.model.abort()
            try await waitUntil { controller.model.output.contains("tracked paths") && FileManager.default.fileExists(atPath: streamReady.path) }
            let pid = Int32(try String(contentsOf: streamReady).trimmingCharacters(in: .whitespacesAndNewlines))!
            let progress = controller.progress!, progressWindow = progress.window!
            var delayedReply: ((Bool) -> Void)?
            if scenario == "stale" { controller.model.confirmCancellation = { delayedReply = $0 } }
            key(progressWindow, 53, "\u{1b}")
            precondition(controller.model.confirmingCancellation && controller.model.busy && kill(pid, 0) == 0)
            let alert = progress.cancellationAlert
            if scenario != "stale" {
                precondition(alert?.messageText == "The process is still running." && alert?.informativeText == "Are you sure to abort?")
                precondition(progressWindow.attachedSheet === alert!.window && alert!.window.sheetParent === progressWindow)
                precondition(alert!.buttons.map(\.title) == ["Yes", "No"])
            }
            controller.model.cancel(); controller.model.close(); key(progressWindow, 36, "\r")
            precondition(controller.model.confirmingCancellation && controller.progress === progress)
            precondition(!progress.windowShouldClose(progressWindow) && delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
            if scenario.hasPrefix("finished") {
                try Data().write(to: release)
                try await waitUntil { !controller.model.busy }
                precondition(controller.model.success && !controller.model.cancelled && controller.model.confirmingCancellation && progressWindow.isVisible)
                precondition(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
                alert!.buttons[scenario == "finished-no" ? 1 : 0].performClick(nil)
                try await waitUntil({ controller.progress == nil }, diagnostic: { "scenario=\(scenario) busy=\(controller.model.busy) confirming=\(controller.model.confirmingCancellation) sheet=\(progressWindow.attachedSheet != nil) policy=\(preferences.integer(forKey: "AutoCloseGitProgress"))" })
                precondition(controller.model.success && !controller.model.cancelled && changes == 1)
            } else if scenario == "decline" {
                alert!.buttons[1].performClick(nil)
                try await waitUntil { !controller.model.confirmingCancellation && progressWindow.attachedSheet == nil }
                precondition(controller.model.busy && kill(pid, 0) == 0 && controller.progress === progress)
                try Data().write(to: release); try await waitUntil { !controller.model.busy }
                precondition(controller.model.success && !controller.model.cancelled && changes == 1)
                controller.model.close()
            } else if scenario == "accept" {
                alert!.buttons[0].performClick(nil)
                try await waitUntil { !controller.model.busy && controller.progress == nil && kill(pid, 0) == -1 }
                precondition(controller.model.cancelled && !controller.model.success && changes == 1)
            } else {
                if scenario == "stale" {
                    let firstReply = delayedReply!
                    firstReply(false); firstReply(true)
                    precondition(!controller.model.confirmingCancellation && controller.model.busy && kill(pid, 0) == 0)
                    controller.model.cancel()
                    precondition(controller.model.confirmingCancellation)
                    firstReply(true)
                    precondition(controller.model.confirmingCancellation && controller.model.busy && kill(pid, 0) == 0)
                }
                let before = controller.model.output
                controller.window!.close()
                delayedReply?(true); delayedReply?(false)
                try await waitUntil { !controller.model.busy && kill(pid, 0) == -1 }
                precondition(!controller.model.confirmingCancellation && changes == 0 && controller.model.output == before && controller.progress == nil)
                if let alert { precondition(alert.window.sheetParent == nil && !alert.window.isVisible) }
            }
            precondition(controller.progress == nil && !progressWindow.isVisible && progressWindow.attachedSheet == nil)
        }
        preferences.removeObject(forKey: "ConfirmKillProcess"); preferences.removeObject(forKey: "AutoCloseGitProgress")
        print("Abort confirmation: actual owned Yes/No sheet; decline preserves active command; accept cancels/reaps and retires progress; duplicate/close/Quit gates; completion while prompt pending delays auto-close and keeps success; forced sheet teardown and late/duplicate replies rejected. Private preferences.")
        preferences.removeObject(forKey: "GitOutputLimitinKiB")
        print("Abort live output: stdout/stderr before completion, UTF-8, failure status without duplicate output, ordinary cancel retention, forced-close late-output fencing, 16KiB display limit; all hidden windows closed.")
        let keyboardCancel = MergeAbortWindowController(repository: repo, access: nil, preferences: preferences)
        keyboardCancel.window!.alphaValue = 0; keyboardCancel.window!.orderFront(nil)
        key(keyboardCancel.window!, 53, "\u{1b}")
        precondition(!keyboardCancel.window!.isVisible && !keyboardCancel.model.showingProgress)
        print("Abort native keyboard: Return opens separate progress; keypad Enter closes terminal progress; Return while busy does not close; Escape cancels active reset, closes terminal progress/options; parent Return/Escape fenced while comparison sheet attached.")
        var closes = 0, aborts = 0
        let progress = MergeProgressWindowModel(repository: repo, access: nil, options: options, target: .branch, showStashPop: false)
        progress.close = { closes += 1 }; progress.onAbortRequested = { aborts += 1 }
        await progress.run(); precondition(!progress.success && progress.postActions.contains(.resolve))
        let conflict = try Data(contentsOf: root.appendingPathComponent("file"))
        progress.close(); precondition(closes == 1 && aborts == 0)
        let closedFile = try Data(contentsOf: root.appendingPathComponent("file")); precondition(closedFile == conflict)
        progress.cancelResult(); progress.cancelResult(); progress.perform(.stash)
        try await waitUntil { !progress.checkingDismissal }
        precondition(closes == 2 && aborts == 1)
        try Data("resolved\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"])
        progress.cancelResult(); try await waitUntil { !progress.checkingDismissal }
        precondition(closes == 3 && aborts == 1, "Cancel must freshly check resolved conflicts")
        _ = try await repo.run(["reset", "--hard"])
        for mode in MergeAbortMode.allCases {
            do { _ = try await repo.merge(options); preconditionFailure("Expected conflict") } catch is GitFailure {}
            let before = try Data(contentsOf: root.appendingPathComponent("file"))
            try Data("untracked\n".utf8).write(to: root.appendingPathComponent("untracked"))
            let model = MergeAbortWindowModel(repository: repo, access: nil, preferences: preferences)
            model.mode = mode; var changed = 0, resize: [Bool] = [], action: MergeAbortPostAction?
            model.onChanged = { _ in changed += 1 }; model.onResize = { resize.append($0) }; model.onPostAction = { action = $0 }
            model.abort(); model.mode = mode == .mixed ? .hard : .mixed; model.abort(); model.showModified()
            try await waitUntil { !model.busy }
            precondition(model.success && model.showingProgress && changed == 1 && resize == [true])
            let actualHead = try await repo.run(["rev-parse", "HEAD"]).stdout, conflicts = try await repo.conflicts()
            let after = try Data(contentsOf: root.appendingPathComponent("file"))
            precondition(actualHead == head && conflicts.isEmpty && after == (mode == .mixed ? before : Data("ours\n".utf8)))
            let untracked = try Data(contentsOf: root.appendingPathComponent("untracked")); precondition(untracked == Data("untracked\n".utf8))
            precondition(model.postActions == (mode == .hard ? [.clean] : []))
            if mode == .hard { model.perform(.clean); precondition(action == .clean) }
            _ = try await repo.run(["reset", "--hard"])
        }
        for mode in MergeAbortMode.allCases {
            let lock = root.appendingPathComponent(".git/index.lock")
            try Data().write(to: lock)
            let model = MergeAbortWindowModel(repository: repo, access: nil, preferences: preferences); model.mode = mode; model.abort()
            try await waitUntil { !model.busy }
            precondition(!model.success && model.postActions == [.retry])
            try FileManager.default.removeItem(at: lock)
            model.perform(.retry)
            if mode == .merge {
                precondition(!model.showingProgress && model.mode == .merge && !model.busy)
                model.abort()
            } else { precondition(model.showingProgress && model.busy) }
            try await waitUntil { !model.busy }; precondition(model.success)
        }
        // Source mixed/hard reset success adds all four Bisect actions when active.
        _ = try await repo.run(["bisect", "start"])
        let mixed = MergeAbortWindowModel(repository: repo, access: nil, preferences: preferences); mixed.mode = .mixed; mixed.abort()
        try await waitUntil { !mixed.busy }; precondition(mixed.success && mixed.postActions == [.good, .bad, .skip, .reset])
        _ = try await repo.run(["bisect", "reset"])
        precondition(MergeAbortPostAction.good.bisectOperation == .good && MergeAbortPostAction.retry.bisectOperation == nil)
        print("Abort Merge: defaults/comparison/idle nonmutation/invalidation; Cancel vs Close, duplicate dismissal and fresh conflict resolution; all three real reset modes and captured selection; untracked/HEAD preservation; lock failures and mode-specific Retry; active Bisect post-actions. Hidden controller windows closed; private preferences; no clipboard writes.")
    }
}
