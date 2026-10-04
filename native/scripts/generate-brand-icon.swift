// Reproducible vector rendering of the approved Axon mark; no external dependencies.
import AppKit
import Foundation
let output = CommandLine.arguments[1]
let white = CommandLine.arguments.dropFirst(2).first == "white"
let iconName = white ? "AppIconWhite" : "AppIcon"
let sizes = [16, 32, 128, 256, 512]
func render(_ size: Int, to path: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    cg.translateBy(x: 0, y: 1024)
    cg.scaleBy(x: 1, y: -1)
    // Both choices use the same Finder custom-icon rendering path. Balance
    // their Dock outline between the former inset black and larger white icons.
    let artworkScale: CGFloat = 0.95
    cg.translateBy(x: 512, y: 512)
    cg.scaleBy(x: artworkScale, y: artworkScale)
    cg.translateBy(x: -512, y: -512)
    cg.setFillColor((white ? NSColor(srgbRed: 250/255, green: 250/255, blue: 250/255, alpha: 1) : NSColor(srgbRed: 41/255, green: 43/255, blue: 45/255, alpha: 1)).cgColor)
    cg.addPath(CGPath(roundedRect: CGRect(x: 56, y: 56, width: 912, height: 912), cornerWidth: 203, cornerHeight: 203, transform: nil))
    cg.fillPath()
    // Leave comfortable space around the complete A + amber mark, comparable
    // to the visual padding of neighbouring macOS Dock icons such as Safari.
    cg.translateBy(x: 512, y: 510)
    cg.scaleBy(x: 1.30, y: 1.30)
    cg.translateBy(x: -512, y: -490)
    cg.setFillColor((white ? NSColor(srgbRed: 22/255, green: 22/255, blue: 22/255, alpha: 1) : NSColor(srgbRed: 245/255, green: 245/255, blue: 242/255, alpha: 1)).cgColor)
    for points: [CGPoint] in [[CGPoint(x:240,y:716),CGPoint(x:510,y:264),CGPoint(x:568,y:364),CGPoint(x:370,y:716)], [CGPoint(x:572,y:440),CGPoint(x:784,y:716),CGPoint(x:640,y:716),CGPoint(x:508,y:544)]] {
        cg.move(to: points[0]); points.dropFirst().forEach { cg.addLine(to: $0) }; cg.closePath(); cg.fillPath()
    }
    cg.setFillColor(NSColor(srgbRed:245/255,green:180/255,blue:60/255,alpha:1).cgColor)
    cg.fill(CGRect(x:477,y:619,width:66,height:66))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
try FileManager.default.createDirectory(atPath: output + "/\(iconName).iconset", withIntermediateDirectories: true)
for size in sizes {
    try render(size, to: output + "/\(iconName).iconset/icon_\(size)x\(size).png")
    try render(size * 2, to: output + "/\(iconName).iconset/icon_\(size)x\(size)@2x.png")
}
try render(1024, to: output + (white ? "/axon-icon-white.png" : "/axon-icon.png"))
