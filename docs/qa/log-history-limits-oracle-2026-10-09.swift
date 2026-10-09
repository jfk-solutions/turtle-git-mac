import Foundation
import TurtleGitCore

struct LimitCase: Decodable {
    let scale: Int
    let number: UInt32
    let midnight: Int64
    let from: Int64
    let until: Int64
}
@main struct HistoryLimitOracle {
    static func main() throws {
        let cases = try JSONDecoder().decode([LimitCase].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let results = cases.map { item -> [String] in
            let scope = HistoryLimitScope(defaults: .init(scale: HistoryLimitScale(rawValue: item.scale)!, number: item.number), from: item.from == -1 ? nil : Date(timeIntervalSince1970: TimeInterval(item.from)), until: item.until == -1 ? nil : Date(timeIntervalSince1970: TimeInterval(item.until)))
            var options = HistoryOptions(); scope.apply(to: &options, now: Date(timeIntervalSince1970: TimeInterval(item.midnight + 1)), calendar: calendar)
            var args: [String] = []
            if options.limit >= 0 { args.append("-n\(options.limit)") }
            if let since = options.since { args.append("--max-age=\(Int64(since.timeIntervalSince1970))") }
            if let until = options.until { args.append("--min-age=\(Int64(until.timeIntervalSince1970))") }
            return args
        }
        print(String(decoding: try JSONEncoder().encode(results), as: UTF8.self))
    }
}
