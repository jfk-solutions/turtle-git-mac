import Foundation

public enum UnifiedDiffMarginUnit: Sendable {
    case millimeters, inches
    public var pointsPerUnit: Double { self == .millimeters ? 72 / 25.4 : 72 }
    public var label: String { self == .millimeters ? "mm" : "in" }
}

/// UDiff's 2540 hundredths of a millimeter / 1000 thousandths of an inch defaults
/// both equal 72 native print points. Store points independently of locale changes.
public struct UnifiedDiffPrintMargins: Codable, Equatable, Sendable {
    public var left: Double = 72
    public var top: Double = 72
    public var right: Double = 72
    public var bottom: Double = 72
    public init() {}
    public var isValid: Bool { [left, top, right, bottom].allSatisfy { $0.isFinite && $0 >= 0 } }
    public func fits(width: Double, height: Double) -> Bool {
        isValid && width.isFinite && height.isFinite && left + right < width && top + bottom < height
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "TurtleGit.UnifiedDiffPrintMargins"),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return Self() }
        return value
    }
    @discardableResult public func save(to defaults: UserDefaults = .standard) -> Bool {
        guard isValid, let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: "TurtleGit.UnifiedDiffPrintMargins"); return true
    }
}
