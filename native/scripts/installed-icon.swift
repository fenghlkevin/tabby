import AppKit
import CoreServices

// Restore the saved Finder/Dock icon without launching Axon or editing signed Contents.
let app = URL(fileURLWithPath: CommandLine.arguments[1])
let workspace = URL(fileURLWithPath: CommandLine.arguments[2])
let style: String
if FileManager.default.fileExists(atPath: workspace.path) {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: workspace)) as? [String: Any]
    style = (object?["preferences"] as? [String: Any])?["applicationIcon"] as? String ?? "black"
} else { style = "black" }
guard ["black", "white"].contains(style),
      let image = NSImage(contentsOf: app.appendingPathComponent("Contents/Resources/" + (style == "white" ? "AppIconWhite.icns" : "AppIconBlack.icns"))),
      NSWorkspace.shared.setIcon(image, forFile: app.path, options: []) else {
    throw NSError(domain: "AxonInstallIcon", code: 1)
}
let status = LSRegisterURL(app as CFURL, true)
guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
NSWorkspace.shared.noteFileSystemChanged(app.path)
print("Installed file icon: " + style + "; application was not launched")

if CommandLine.arguments.count > 3 {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSWorkspace.shared.icon(forFile: app.path).draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
}
