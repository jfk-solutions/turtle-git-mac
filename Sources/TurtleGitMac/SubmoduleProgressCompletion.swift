// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// ProgressDlg's completion line. Date formatting follows the user's macOS locale.
struct SubmoduleProgressCompletion {
    let currentWork: String
    let text: String
    init(success: Bool, cancelled: Bool, exitCode: Int32?, elapsed: TimeInterval, finished: Date = Date(), preferences: UserDefaults) {
        if success { currentWork = "Success" }
        else if cancelled { currentWork = "User cancelled" }
        else if let exitCode { currentWork = "git did not exit cleanly (exit code \(exitCode))" }
        else { currentWork = "Operation failed" }
        let timings = (preferences.object(forKey:"ShowGitexeTimings") as? NSNumber)?.boolValue ?? true
        let milliseconds = Int64(max(0, min(elapsed.isFinite ? elapsed : 0, Double(Int64.max / 2000))) * 1000)
        let stamp: String
        if (preferences.object(forKey:"UseSystemLocaleForDates") as? NSNumber)?.boolValue ?? true {
            stamp = DateFormatter.localizedString(from:finished, dateStyle:.short, timeStyle:.medium)
        } else {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.calendar = Calendar(identifier:.gregorian)
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"; stamp = formatter.string(from:finished)
        }
        text = (success ? "\n" : "\n\n") + currentWork + (timings ? " (\(milliseconds) ms @ \(stamp))" : "") + "\n"
    }
    func append(to output: inout String) -> NSRange {
        let range = NSRange(location:(output as NSString).length,length:(text as NSString).length)
        output += text; return range
    }
}
