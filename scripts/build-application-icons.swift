// SPDX-License-Identifier: GPL-2.0-or-later
// Format conversion only: keep original upstream artwork and use exact native
// application artwork at every size. Document slots retain exact small frames.
import AppKit
import ImageIO
import CryptoKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let branding = root.appendingPathComponent("Sources/TurtleGitMac/Resources/Branding")
let assets = root.appendingPathComponent("Sources/TurtleGitMac/Resources/ApplicationAssets.xcassets")
let fm = FileManager.default
func writePNG(source: URL, pixels: Int, to output: URL) throws {
    guard let input = CGImageSourceCreateWithURL(source as CFURL, nil) else { fatalError("Unreadable upstream icon") }
    let frames = (0..<CGImageSourceGetCount(input)).compactMap { CGImageSourceCreateImageAtIndex(input, $0, nil) }
    guard let image = frames.first(where: { $0.width == pixels && $0.height == pixels }) ?? frames.max(by: { $0.width < $1.width }),
          let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("No icon pixels") }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: output)
}
try Data("{\"info\":{\"author\":\"TurtleGit\",\"version\":1}}\n".utf8).write(to: assets.appendingPathComponent("Contents.json"))
try writePNG(source: branding.appendingPathComponent("Upstream/Tortoise.ico"), pixels: 256, to: branding.appendingPathComponent("ApplicationIcon.png"))
var records: [[String: Any]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try writePNG(source: branding.appendingPathComponent("ApplicationIcon.png"), pixels: size * scale, to: assets.appendingPathComponent("AppIcon.appiconset/" + name))
        records.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": records, "info": ["author": "TurtleGit", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: assets.appendingPathComponent("AppIcon.appiconset/Contents.json"))
// Share the packaged application's complete turtle/Git artwork with native
// menus, Finder, About and standalone authentication helpers. Keep the original
// vendored TortoiseSmall.ico unchanged for source provenance.
let sharedIcon = root.appendingPathComponent("Sources/TurtleGitCore/Resources/Icons/TurtleGitApplication.png")
try? fm.removeItem(at: sharedIcon)
try fm.copyItem(at: branding.appendingPathComponent("ApplicationIcon.png"), to: sharedIcon)
let scratch = fm.temporaryDirectory.appendingPathComponent("TurtleGitPatch-" + UUID().uuidString + ".iconset", isDirectory: true)
try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: scratch) }
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try writePNG(source: branding.appendingPathComponent("Upstream/TortoiseUDiff.ico"), pixels: size * scale, to: scratch.appendingPathComponent(name))
    }
}
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", scratch.path, "-o", branding.appendingPathComponent("TurtleGitPatch.icns").path]
try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Converted original application/document icons and ten macOS AppIcon slots; no new artwork.")

func hash(_ file: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined() }
let sourceFiles = [("Tortoise.ico", "src/Resources/Tortoise.ico"), ("TortoiseUDiff.ico", "src/TortoiseUDiff/TortoiseUDiff.ico")]
var sources: [[String: String]] = []
for (name, path) in sourceFiles { sources.append(["asset": "Upstream/" + name, "source": path, "sha256": try hash(branding.appendingPathComponent("Upstream/" + name))]) }
var outputs: [String: String] = [:]
for folder in [branding, assets] {
    let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])!
    for case let file as URL in enumerator where file.lastPathComponent != "provenance.json" {
        if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { outputs[String(file.path.dropFirst(root.path.count + 1))] = try hash(file) }
    }
}
outputs["Sources/TurtleGitCore/Resources/Icons/TurtleGitApplication.png"] = try hash(sharedIcon)
let manifest: [String: Any] = ["upstream": "https://github.com/TortoiseGit/TortoiseGit", "commit": "7338078f8ddd924b8cddee35f512f2286072136d", "license_choice": "GNU GPL alternative in upstream src/Resources/license.txt", "sources": sources, "conversion": "scripts/build-application-icons.swift; application and shared branding use the complete 256px turtle/Git frame at every size; document icons prefer exact-size frames; original artwork and transparency, no new design", "outputs": outputs]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: branding.appendingPathComponent("provenance.json"))
let webIcon = root.appendingPathComponent("docs/site/assets/application-icon.png")
try? fm.removeItem(at: webIcon); try fm.copyItem(at: branding.appendingPathComponent("ApplicationIcon.png"), to: webIcon)
