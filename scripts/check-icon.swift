import AppKit
import Foundation

// Run with xcrun swift -swift-version 6 scripts/check-icon.swift <app paths...>.
// Reads our bundle resources and exports the icon returned by NSWorkspace.
let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/validation", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (index, path) in CommandLine.arguments.dropFirst().enumerated() {
    guard let bundle = Bundle(url: URL(fileURLWithPath: path)),
          let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
          let resource = bundle.url(forResource: name, withExtension: "icns"),
          let image = NSImage(contentsOf: resource), image.isValid else {
        fatalError("Missing or unreadable bundled icon: \(path)")
    }
    let sizes = image.representations.map { "\($0.pixelsWide)x\($0.pixelsHigh)" }
    guard image.representations.contains(where: { $0.pixelsWide == 1024 }) else { fatalError("Missing high-resolution icon") }
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot render bundle icon") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    NSWorkspace.shared.icon(forFile: path).draw(in: NSRect(x: 0, y: 0, width: 128, height: 128), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("app-icon-\(index).png"))
    print("Verified \(path): \(name).icns, representations: \(sizes.joined(separator: ", "))")
}
