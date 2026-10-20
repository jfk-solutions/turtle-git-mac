// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

/// Holds a closed filesystem workflow until its actual worker and native child
/// releases complete. Visual closure never releases repository scopes early.
@MainActor final class FinderFilesystemWorkflowRelease {
    private(set) static var activeRetirements=0
    private let ready:()->Bool
    private let completion:()->Void
    init(ready:@escaping()->Bool,completion:@escaping()->Void){self.ready=ready;self.completion=completion}
    func start(){
        Self.activeRetirements += 1
        Task { @MainActor [self] in
            defer{Self.activeRetirements -= 1}
            // AppKit may detach sheets on its next main-loop pass.
            await Task.yield()
            while !ready(){try? await Task.sleep(nanoseconds:10_000_000)}
            completion()
        }
    }
}
