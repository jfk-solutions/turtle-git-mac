// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

// OpenSSH receives this program's stdout through its own passphrase pipe.
// Never print a credential to stderr or accept one in argv/environment.
func credential() throws -> Data {
    guard let path = ProcessInfo.processInfo.environment["TURTLEGIT_SSH_CREDENTIAL_FILE"], path.hasPrefix("/"), !path.utf8.contains(0) else { throw CocoaError(.fileReadInvalidFileName) }
    let file = URL(fileURLWithPath: path), name = file.lastPathComponent, parent = file.deletingLastPathComponent()
    guard name.hasPrefix("credential-"), parent.lastPathComponent.hasPrefix("tg-agent-") else { throw CocoaError(.fileReadNoPermission) }
    let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw CocoaError(.fileReadNoPermission) }; defer { close(directory) }
    var directoryInfo = stat()
    guard fstat(directory, &directoryInfo) == 0, directoryInfo.st_uid == getuid(), directoryInfo.st_mode & 0o777 == 0o700 else { throw CocoaError(.fileReadNoPermission) }
    let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }; defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600, info.st_nlink == 1, info.st_size > 0, info.st_size <= 65_536 else { throw CocoaError(.fileReadNoPermission) }
    var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(descriptor, &buffer, buffer.count)
        if count < 0 { if errno == EINTR { continue }; throw CocoaError(.fileReadUnknown) }
        if count == 0 { break }
        bytes.append(contentsOf: buffer.prefix(count)); guard bytes.count <= 65_536 else { throw CocoaError(.fileReadTooLarge) }
    }
    let magic = Data("TurtleGitSSHAskpass\0".utf8)
    guard bytes.starts(with: magic) else { throw CocoaError(.fileReadCorruptFile) }
    let value = Data(bytes.dropFirst(magic.count))
    guard String(data: value, encoding: .utf8) != nil, !value.contains(0), !value.contains(10), !value.contains(13) else { throw CocoaError(.fileReadCorruptFile) }
    // Recheck the envelope inode before consuming its private-directory entry.
    var current = stat()
    guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0, current.st_dev == info.st_dev, current.st_ino == info.st_ino, unlinkat(directory, name, 0) == 0 else { throw CocoaError(.fileReadNoPermission) }
    return value + Data([10])
}

do { try FileHandle.standardOutput.write(contentsOf: credential()) }
catch { exit(1) }
