import Foundation

public enum CleanType: Int, CaseIterable, Sendable {
    case all = 0, nonIgnored = 1, ignored = 2
}

public struct CleanOptions: Equatable, Sendable {
    public var type: CleanType
    public var directories: Bool { didSet { if !directories { unmanagedRepositories = false } } }
    public var unmanagedRepositories: Bool
    public init(type: CleanType = .all, directories: Bool = true, unmanagedRepositories: Bool = false) {
        self.type = type; self.directories = directories
        self.unmanagedRepositories = directories && unmanagedRepositories
    }
    var previewArguments: [String] {
        ["-c", "core.quotepath=true", "clean", "-n"] + (directories ? ["-d"] : []) +
            [type == .all ? "-fx" : type == .ignored ? "-fX" : "-f"] +
            (directories && unmanagedRepositories ? ["-f"] : [])
    }
}

public struct CleanPreview: Sendable {
    public let options: CleanOptions
    public let paths: [String]
    public let output: Data
    /// Literal root-relative candidates; trailing slash denotes a directory.
    public let candidates: [String]
}

public enum CleanFailure: LocalizedError {
    case bare, path, output
    public var errorDescription: String? {
        switch self {
        case .bare: return "Clean requires a working tree."
        case .path: return "Choose paths inside the working tree."
        case .output: return "Git returned an unrecognized cleanup path. No files were removed."
        }
    }
}

extension GitRepository {
    /// Read-only clean plan. Caller supplies literal scopes; Finder file requests
    /// must be converted to their containing directory by the dialog coordinator.
    public func cleanPreview(options: CleanOptions = CleanOptions(), paths: [String] = [], cancellation: OperationCancellation? = nil) throws -> CleanPreview {
        try cancellation?.check()
        let environment = ["GIT_OPTIONAL_LOCKS": "0"]
        guard try run(["rev-parse", "--is-bare-repository"], environmentOverrides: environment, cancellation: cancellation).text.trimmingCharacters(in: .newlines) != "true" else { throw CleanFailure.bare }
        guard paths.allSatisfy(Self.validCleanPath) else { throw CleanFailure.path }
        let output = try run(options.previewArguments + ["--"] + paths, environmentOverrides: environment, cancellation: cancellation).stdout
        var candidates: [String] = []
        for line in output.split(separator: 10) {
            let prefix = Array("Would remove ".utf8)
            guard line.starts(with: prefix) else { continue } // e.g. skipped nested repository
            let encoded = Array(line.dropFirst(prefix.count))
            let bytes: [UInt8]
            if encoded.first == 34 {
                guard encoded.count >= 2, encoded.last == 34 else { throw CleanFailure.output }
                var decoded: [UInt8] = [], index = 1
                while index < encoded.count - 1 {
                    let byte = encoded[index]; index += 1
                    if byte != 92 { decoded.append(byte); continue }
                    guard index < encoded.count - 1 else { throw CleanFailure.output }
                    let escaped = encoded[index]; index += 1
                    let escapes: [UInt8: UInt8] = [97: 7, 98: 8, 116: 9, 110: 10, 118: 11, 102: 12, 114: 13, 34: 34, 92: 92]
                    if let value = escapes[escaped] { decoded.append(value) }
                    else if (48...55).contains(escaped) {
                        guard index + 1 < encoded.count - 1, (48...55).contains(encoded[index]), (48...55).contains(encoded[index + 1]) else { throw CleanFailure.output }
                        let value = Int(escaped - 48) * 64 + Int(encoded[index] - 48) * 8 + Int(encoded[index + 1] - 48)
                        guard value <= 255 else { throw CleanFailure.output }
                        decoded.append(UInt8(value)); index += 2
                    } else { throw CleanFailure.output }
                }
                bytes = decoded
            } else { bytes = encoded }
            guard let path = String(bytes: bytes, encoding: .utf8), Self.validCleanPath(path) else { throw CleanFailure.output }
            candidates.append(path)
        }
        try cancellation?.check()
        return CleanPreview(options: options, paths: paths, output: output, candidates: candidates)
    }
    private static func validCleanPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") &&
            !path.split(separator: "/").contains(where: { $0 == ".." || $0 == ".git" })
    }
}
