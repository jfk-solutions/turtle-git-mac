// SPDX-License-Identifier: GPL-2.0-or-later
// Reproducible size/format derivatives of the preserved custom TurtleGit artwork.
// Vendored upstream icons remain unchanged and are not active branding inputs.
import AppKit
import ImageIO
import CryptoKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let branding = root.appendingPathComponent("Sources/TurtleGitMac/Resources/Branding")
let assets = root.appendingPathComponent("Sources/TurtleGitMac/Resources/ApplicationAssets.xcassets")
let fm = FileManager.default
func hash(_ file: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined() }
let source = branding.appendingPathComponent("TurtleGitIconSource.png")
let sourceProvenance = branding.appendingPathComponent("TurtleGitIconSource.provenance.json")
guard let artwork = try JSONSerialization.jsonObject(with: Data(contentsOf: sourceProvenance)) as? [String: Any],
      artwork["asset"] as? String == source.lastPathComponent,
      artwork["sha256"] as? String == (try hash(source)),
      ["prompt", "generator", "license"].allSatisfy({ !(artwork[$0] as? String ?? "").isEmpty }),
      let input = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(input) == 1,
      let original = CGImageSourceCreateImageAtIndex(input, 0, nil),
      original.width == original.height, (1024...4096).contains(original.width),
      artwork["width"] as? Int == original.width, artwork["height"] as? Int == original.height else {
    fatalError("Custom source requires matching provenance and a square PNG of 1024–4096 pixels")
}
func raster(_ image: CGImage, pixels: Int) -> CGContext {
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { fatalError("No icon raster") }
    context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels)); context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels)); return context
}
let originalRaster = raster(original, pixels: original.width)
guard let bytes = originalRaster.data?.assumingMemoryBound(to: UInt8.self),
      (0..<(original.width * original.height)).contains(where: { bytes[$0 * 4 + 3] == 0 }),
      (0..<(original.width * original.height)).contains(where: { bytes[$0 * 4 + 3] > 0 }) else { fatalError("Custom source must contain real transparent and painted pixels") }
func writePNG(pixels: Int, to output: URL) throws {
    let bitmap = NSBitmapImageRep(cgImage: raster(original, pixels: pixels).makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: output, options: .atomic)
}
try Data("{\"info\":{\"author\":\"TurtleGit\",\"version\":1}}\n".utf8).write(to: assets.appendingPathComponent("Contents.json"), options: .atomic)
try writePNG(pixels: 1024, to: branding.appendingPathComponent("ApplicationIcon.png"))
var records: [[String: Any]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try writePNG(pixels: size * scale, to: assets.appendingPathComponent("AppIcon.appiconset/" + name))
        records.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": records, "info": ["author": "TurtleGit", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: assets.appendingPathComponent("AppIcon.appiconset/Contents.json"), options: .atomic)
// Native menus, Finder, About and authentication helpers share the 512px custom
// mascot, including its Git lettering. Original upstream resource icons stay intact.
let sharedIcon = root.appendingPathComponent("Sources/TurtleGitCore/Resources/Icons/TurtleGitApplication.png")
try Data(contentsOf: assets.appendingPathComponent("AppIcon.appiconset/icon_512x512.png")).write(to: sharedIcon, options: .atomic)
let scratch = fm.temporaryDirectory.appendingPathComponent("TurtleGitPatch-" + UUID().uuidString + ".iconset", isDirectory: true)
try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: scratch) }
for record in records {
    let name = record["filename"] as! String
    try fm.copyItem(at: assets.appendingPathComponent("AppIcon.appiconset/" + name), to: scratch.appendingPathComponent(name))
}
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", scratch.path, "-o", branding.appendingPathComponent("TurtleGitPatch.icns").path]
try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
let webIcon = root.appendingPathComponent("docs/site/assets/application-icon.png")
try Data(contentsOf: assets.appendingPathComponent("AppIcon.appiconset/icon_256x256.png")).write(to: webIcon, options: .atomic)
let webFavicon = root.appendingPathComponent("docs/site/assets/application-favicon.png")
try Data(contentsOf: assets.appendingPathComponent("AppIcon.appiconset/icon_32x32.png")).write(to: webFavicon, options: .atomic)
let upstreamFiles = [
    ("Tortoise.ico", "src/Resources/Tortoise.ico", "dd7d0bb42b72d565723cdaf0687ed3ce5afd30ef743248d35cac78532e4e6eac"),
    ("TortoiseUDiff.ico", "src/TortoiseUDiff/TortoiseUDiff.ico", "8678b929d02355e510b77adbcee99a4cbc5ced1673df952d6a50e8f70005b242")
]
var upstream: [[String: Any]] = []
for (name, path, digest) in upstreamFiles {
    guard try hash(branding.appendingPathComponent("Upstream/" + name)) == digest else { fatalError("Vendored upstream icon changed") }
    upstream.append(["asset": "Upstream/" + name, "source": path, "sha256": digest, "active_branding": false])
}
var outputs: [String: String] = [:]
for folder in [branding, assets] {
    let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])!
    for case let file as URL in enumerator where file.lastPathComponent != "provenance.json" {
        if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { outputs[String(file.path.dropFirst(root.path.count + 1))] = try hash(file) }
    }
}
outputs["Sources/TurtleGitCore/Resources/Icons/TurtleGitApplication.png"] = try hash(sharedIcon)
outputs["docs/site/assets/application-icon.png"] = try hash(webIcon)
outputs["docs/site/assets/application-favicon.png"] = try hash(webFavicon)
let manifest: [String: Any] = [
    "schema": 2, "artwork": artwork,
    "sources": [["asset": source.lastPathComponent, "sha256": try hash(source), "kind": "custom_generated_artwork"]],
    "vendored_upstream": ["repository": "https://github.com/TortoiseGit/TortoiseGit", "commit": "7338078f8ddd924b8cddee35f512f2286072136d", "license_choice": "GNU GPL alternative in upstream src/Resources/license.txt", "sources": upstream],
    "conversion": "scripts/build-application-icons.swift; preserved custom source resampled to 1024px ApplicationIcon, ten AppIcon slots, 512px shared native artwork, 256px web icon, 32px favicon and matching custom patch-document ICNS; no upstream artwork used for active branding", "outputs": outputs
]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: branding.appendingPathComponent("provenance.json"), options: .atomic)
print("Derived custom TurtleGit application, native, website and patch-document artwork with source/prompt provenance; vendored upstream originals retained unchanged.")
